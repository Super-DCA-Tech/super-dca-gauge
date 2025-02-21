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
 * @title SuperDCAGauge
 * @notice A Uniswap V4 pool hook that implements a staking and reward distribution system.
 * @dev This contract allows users to stake SuperDCATokens for specific token pools and earn rewards
 *      based on their staked amount and time. Rewards are distributed when liquidity is added or
 *      removed from the associated Uniswap V4 pools.
 *
 * Key features:
 * - Staking: Users can stake SuperDCATokens for specific token pools
 * - Reward Distribution: Rewards are calculated based on staked amount and time
 * - Pool Integration: Rewards are split between the pool (community) and developer
 *
 * Reward calculation:
 * - Global reward index increases based on time and mint rate
 * - Individual rewards = staked_amount * (current_index - last_claim_index)
 * - Distribution: 50% to pool (community), 50% to developer
 */
contract SuperDCAGauge is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using EnumerableSet for EnumerableSet.AddressSet;

    // Constants
    uint256 public constant POOL_FEE = 500;

    /**
     * @notice Information about a token's staking and rewards
     * @param stakedAmount Total amount of SuperDCATokens staked for this token
     * @param lastRewardIndex The reward index when rewards were last claimed
     */
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
    uint256 public rewardIndex = 0;
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
    error InvalidPoolFee();
    error PoolMustIncludeSuperDCAToken();

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
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
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
     * @notice Validates that the pool contains SuperDCAToken and has the correct fee
     * @dev Reverts if the pool configuration is invalid
     * @dev Prevents using this hook on non-DCA, 0.05%pools
     * @param sender The address initiating the initialization
     * @param key The pool key containing currency pair and fee information
     * @param sqrtPriceX96 The initial sqrt price of the pool
     * @return The function selector
     */
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        // Validate pool has SuperDCAToken and correct fee
        if (key.fee != POOL_FEE) {
            revert InvalidPoolFee();
        }
        if (
            address(superDCAToken) != Currency.unwrap(key.currency0)
                && address(superDCAToken) != Currency.unwrap(key.currency1)
        ) {
            revert PoolMustIncludeSuperDCAToken();
        }
        return BaseHook.beforeInitialize.selector;
    }

    /**
     * @notice Calculates and returns the reward amount for a specific pool
     * @dev Only processes rewards for pools that include SuperDCAToken and have the correct fee
     * @param key The pool key containing currency pair and fee information
     * @return Amount of reward tokens to be distributed
     */
    function _getRewardTokens(PoolKey calldata key) internal returns (uint256) {
        // Get token reward info for the non-SuperDCAToken currency
        address otherToken = address(superDCAToken) == Currency.unwrap(key.currency0)
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);

        TokenRewardInfo storage tokenInfo = tokenRewardInfos[otherToken];
        if (tokenInfo.stakedAmount == 0) return 0;

        // Update reward index before we mint reward tokens
        _updateRewardIndex();

        // Calculate rewards based on staked amount and reward index delta
        uint256 rewardAmount = tokenInfo.stakedAmount * (rewardIndex - tokenInfo.lastRewardIndex) / 1e18;
        if (rewardAmount == 0) return 0;

        // Update last reward index
        tokenInfo.lastRewardIndex = rewardIndex;

        return rewardAmount;
    }

    /**
     * @notice Handles the distribution of rewards between the pool and developer
     * @dev Syncs the pool manager, calculates rewards, and settles the distribution
     * @param key The pool key identifying the Uniswap V4 pool
     * @param hookData Additional data passed to the hook
     */
    function _handleDistributionAndSettlement(PoolKey calldata key, bytes calldata hookData) internal {
        // Must sync the pool manager to the token before distributing tokens
        poolManager.sync(Currency.wrap(address(superDCAToken)));
        uint256 rewardAmount = _getRewardTokens(key);
        if (rewardAmount == 0) return;

        // Check if pool has liquidity before proceeding with donation
        uint128 liquidity = IPoolManager(msg.sender).getLiquidity(key.toId());
        if (liquidity == 0) {
            // If no liquidity, just send everything to developer
            superDCAToken.transfer(developerAddress, rewardAmount);
            return;
        }

        // Split the mint amount between developer and community
        uint256 developerShare = rewardAmount / 2;
        uint256 communityShare = rewardAmount - developerShare;

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

        /// @dev: At this point, there are DCA tokens left in the hook for the other pools.
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
     * @notice Updates the global reward index based on elapsed time and mint rate
     * @dev The reward index increases proportionally to the time passed and total staked amount
     */
    function _updateRewardIndex() internal {
        if (totalStakedAmount == 0) return;

        uint256 currentTime = block.timestamp;
        uint256 elapsed = currentTime - lastMinted;

        if (elapsed > 0) {
            uint256 mintAmount = elapsed * mintRate;
            // Normalize by 1e18 to maintain precision
            rewardIndex += mintAmount * 1e18 / totalStakedAmount;
            lastMinted = currentTime;
            emit RewardIndexUpdated(rewardIndex);
        }
    }

    /**
     * @notice Allows users to stake SuperDCATokens for a specific token pool
     * @dev Updates reward index before modifying stakes to ensure accurate reward tracking
     * @param token The token address representing the pool to stake for
     * @param amount The amount of SuperDCATokens to stake
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
     * @notice Allows users to unstake their SuperDCATokens from a specific token pool
     * @dev Updates reward index before modifying stakes to ensure accurate reward tracking
     * @param token The token address representing the pool to unstake from
     * @param amount The amount of SuperDCATokens to unstake
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
     * @notice Retrieves all token pools a user has staked in
     * @param user The address of the user to query
     * @return tokens Array of token addresses where the user has active stakes
     */
    function getUserStakedTokens(address user) external view returns (address[] memory) {
        return userStakedTokens[user].values();
    }

    /**
     * @notice Retrieves the stake amount for a specific user and token pool
     * @param user The address of the user to query
     * @param token The token address representing the pool
     * @return amount The amount of SuperDCATokens staked
     */
    function getUserStakeAmount(address user, address token) external view returns (uint256) {
        return userStakes[user][token];
    }

    /**
     * @notice Calculates the pending rewards for a specific token pool
     * @dev Includes unclaimed rewards plus accrued rewards since last update
     * @param token The token address representing the pool
     * @return The total amount of pending rewards
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
