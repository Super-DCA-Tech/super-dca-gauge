// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {BaseHook} from "v4-periphery/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SuperDCAToken} from "./SuperDCAToken.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";


/**
 * @title SuperDCAHook
 * @notice A Uniswap V4 pool hook to distribute SuperDCAToken tokens.
 *   – Before liquidity is added: resets the LP timelock, mints tokens, donates half to the pool,
 *     and transfers half to the developer.
 *   – Before liquidity is removed: if the LP is unlocked (timelock expired), the same distribution occurs.
 *
 * Distribution logic:
 *   mintAmount = (block.timestamp - lastMinted) * mintRate;
 *   community share = mintAmount / 2  (donated via call to donate)
 *   developer share = mintAmount - community share (transferred via ERC20 transfer)
 *
 * The hook is integrated with SuperDCAToken so that its mint() and transfer() functions can be used.
 */
contract SuperDCAHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using EnumerableSet for EnumerableSet.AddressSet;

    // Constants
    uint256 public constant POOL_FEE = 500;

    struct TokenRewardInfo {
        uint256 stakedAmount;
        uint256 lastRewardIndex;
    }

    // State
    SuperDCAToken public superDCAToken;
    address public developerAddress;
    uint256 public mintRate;
    uint256 public lastMinted;

    // Reward tracking
    uint256 public totalStakedAmount;
    uint256 public rewardIndex = 1e18; // Start at 1e18 to avoid division by zero issues
    mapping(address token => TokenRewardInfo info) public tokenRewardInfos;
    mapping(address user => EnumerableSet.AddressSet stakedTokens) private userStakedTokens;
    mapping(address user => mapping(address token => uint256 amount)) public userStakes;

    // Events
    event Staked(address indexed token, address indexed user, uint256 amount);
    event Unstaked(address indexed token, address indexed user, uint256 amount);
    event RewardIndexUpdated(uint256 newIndex);

    // Errors
    error InsufficientBalance();
    error ZeroAmount();

    /**
     * @notice Sets the initial state.
     * @param _poolManager The Uniswap V4 pool manager.
     * @param _superDCAToken The deployed SuperDCAToken contract.
     * @param _developerAddress The address of the Developer.
     * @param _mintRate The number of SuperDCAToken tokens to mint per second.
     */
    constructor(IPoolManager _poolManager, SuperDCAToken _superDCAToken, address _developerAddress, uint256 _mintRate)
        BaseHook(_poolManager)
    {
        superDCAToken = _superDCAToken;
        developerAddress = _developerAddress;
        mintRate = _mintRate;
        lastMinted = block.timestamp;
    }

    /**
     * @notice Returns the hook permissions.
     * Only beforeAddLiquidity and beforeRemoveLiquidity are enabled.
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true, // Enable beforeAddLiquidity
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true, // Enable beforeRemoveLiquidity
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /**
     * @notice Internal function to calculate and distribute tokens.
     */
    function _mintTokens(PoolKey calldata key, bytes calldata hookData) internal returns (uint256) {
        // Validate pool has SuperDCAToken and correct fee
        if (key.fee != POOL_FEE || (
            address(superDCAToken) != Currency.unwrap(key.currency0) && 
            address(superDCAToken) != Currency.unwrap(key.currency1)
        )) {
            return 0;
        }
        
        // Update reward index before we mint reward tokens
        _updateRewardIndex();

        // Get token reward info for the non-SuperDCAToken currency
        address otherToken = address(superDCAToken) == Currency.unwrap(key.currency0) 
            ? Currency.unwrap(key.currency1) 
            : Currency.unwrap(key.currency0);
        
        TokenRewardInfo storage tokenInfo = tokenRewardInfos[otherToken];
        if (tokenInfo.stakedAmount == 0) return 0;

        // Calculate rewards based on staked amount and reward index delta
        uint256 rewardAmount = (tokenInfo.stakedAmount * (rewardIndex - tokenInfo.lastRewardIndex)) / 1e18;
        if (rewardAmount == 0) return 0;

        // Update last reward index
        tokenInfo.lastRewardIndex = rewardIndex;

        // Mint new tokens
        superDCAToken.mint(address(this), rewardAmount);

        return rewardAmount;
    }

    /**
     * @dev Internal function to handle token distribution and settlement
     * @param key The pool key (identifies the pool)
     * @param hookData Arbitrary hook data
     */
    function _handleDistributionAndSettlement(PoolKey calldata key, bytes calldata hookData) internal {
        // Must sync the pool manager to the token before distributing tokens
        poolManager.sync(Currency.wrap(address(superDCAToken)));

        uint256 mintAmount = _mintTokens(key, hookData);
        if (mintAmount == 0) return;

        // Check if pool has liquidity before proceeding with donation
        uint128 liquidity = IPoolManager(msg.sender).getLiquidity(key.toId());
        if (liquidity == 0) {
            // If no liquidity, just send everything to developer
            superDCAToken.transfer(developerAddress, mintAmount);
            return;
        }

        // Split the mint amount between developer and community
        uint256 developerShare = mintAmount / 2;
        uint256 communityShare = mintAmount - developerShare;

        // Donate community share to pool
        if (address(superDCAToken) == Currency.unwrap(key.currency0)) {
            IPoolManager(msg.sender).donate(key, communityShare, 0, hookData);
        } else {
            IPoolManager(msg.sender).donate(key, 0, communityShare, hookData);
        }

        // Transfer developer share
        superDCAToken.transfer(developerAddress, developerShare);

        // Transfer community share
        superDCAToken.transfer(address(poolManager), communityShare);

        // Settle the donation
        poolManager.settle();

        // Invariant:At this point, the hook has no tokens left.
    }

    function _beforeAddLiquidity(
        address, // sender
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata, // params
        bytes calldata hookData
    ) internal override returns (bytes4) {
        _handleDistributionAndSettlement(key, hookData);
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address, // sender
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata, // params
        bytes calldata hookData
    ) internal override returns (bytes4) {
        _handleDistributionAndSettlement(key, hookData);
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    /**
     * @notice Updates the global reward index based on elapsed time
     */
    function _updateRewardIndex() internal {
        if (totalStakedAmount == 0) return;

        uint256 currentTime = block.timestamp;
        uint256 elapsed = currentTime - lastMinted;
        
        if (elapsed > 0) {
            uint256 mintAmount = elapsed * mintRate;
            // Normalize by 1e18 to maintain precision
            rewardIndex += (mintAmount * 1e18) / totalStakedAmount;
            lastMinted = currentTime;
            
            emit RewardIndexUpdated(rewardIndex);
        }
    }

    /**
     * @notice Stakes tokens for a specific token pool
     * @param token The token to stake for
     * @param amount The amount to stake
     */
    function stake(address token, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        
        // Update reward index before modifying stake
        _updateRewardIndex();

        // Transfer tokens from user
        superDCAToken.transferFrom(msg.sender, address(this), amount);

        // Update token reward info
        TokenRewardInfo storage info = tokenRewardInfos[token];
        info.stakedAmount += amount;
        info.lastRewardIndex = rewardIndex;

        // Update total staked amount
        totalStakedAmount += amount;

        // Track user's stake
        userStakedTokens[msg.sender].add(token);
        userStakes[msg.sender][token] += amount;

        emit Staked(token, msg.sender, amount);
    }

    /**
     * @notice Unstakes tokens from a specific token pool
     * @param token The token to unstake from
     * @param amount The amount to unstake
     */
    function unstake(address token, uint256 amount) external {
        TokenRewardInfo storage info = tokenRewardInfos[token];
        
        if (amount == 0) revert ZeroAmount();
        if (info.stakedAmount < amount) revert InsufficientBalance();
        if (userStakes[msg.sender][token] < amount) revert InsufficientBalance();

        // Update reward index before modifying stake
        _updateRewardIndex();

        // Update token reward info
        info.stakedAmount -= amount;
        info.lastRewardIndex = rewardIndex;

        // Update total staked amount
        totalStakedAmount -= amount;

        // Update user's stake
        userStakes[msg.sender][token] -= amount;
        if (userStakes[msg.sender][token] == 0) {
            userStakedTokens[msg.sender].remove(token);
        }

        // Transfer tokens back to user
        superDCAToken.transfer(msg.sender, amount);

        emit Unstaked(token, msg.sender, amount);
    }

    /**
     * @notice Returns the list of tokens a user has staked
     * @param user The address of the user
     * @return tokens Array of token addresses the user has staked
     */
    function getUserStakedTokens(address user) external view returns (address[] memory) {
        return userStakedTokens[user].values();
    }

    /**
     * @notice Returns the stake amount for a specific user and token
     * @param user The address of the user
     * @param token The token address to query
     * @return amount The amount staked
     */
    function getUserStakeAmount(address user, address token) external view returns (uint256) {
        return userStakes[user][token];
    }

    /**
     * @notice Returns the pending rewards for a token
     * @param token The token to check rewards for
     */
    function getPendingRewards(address token) external view returns (uint256) {
        TokenRewardInfo storage info = tokenRewardInfos[token];
        if (info.stakedAmount == 0) return 0;
        if (totalStakedAmount == 0) return 0;

        uint256 currentTime = block.timestamp;
        uint256 elapsed = currentTime - lastMinted;
        uint256 currentIndex = rewardIndex;

        if (elapsed > 0) {
            uint256 mintAmount = elapsed * mintRate;
            currentIndex += (mintAmount * 1e18) / totalStakedAmount;
        }

        return (info.stakedAmount * (currentIndex - info.lastRewardIndex)) / 1e18;
    }
}
