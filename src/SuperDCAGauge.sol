// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {BaseHook} from "v4-periphery/utils/BaseHook.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISuperchainERC20} from "./interfaces/ISuperchainERC20.sol";
import {IMsgSender} from "./interfaces/IMsgSender.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

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
 * - Distribution: 50% to pools (community), 50% to developer
 * - Access Control: Admin can set Manager, Manager can set mintRate
 *
 * Beta Test Scaffolding:
 * - The Super DCA Token is only mintable by the owner (changes in the future)
 * - A MINTER role is added for the Superchain ERC20 version of the Super DCA Token
 * - The developer address is set to superdca.eth
 */
contract SuperDCAGauge is BaseHook, AccessControl {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using EnumerableSet for EnumerableSet.AddressSet;

    // Constants
    uint24 public constant INTERNAL_POOL_FEE = 0; // 0%
    uint24 public constant EXTERNAL_POOL_FEE = 10000; // 1.00%
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

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
    address public superDCAToken;
    address public developerAddress;
    uint24 public internalFee;
    uint24 public externalFee;
    uint256 public mintRate;
    uint256 public lastMinted;
    mapping(address => bool) public isInternalAddress;

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
    event InternalAddressUpdated(address indexed user, bool isInternal);
    event FeeUpdated(bool indexed isInternal, uint24 oldFee, uint24 newFee);
    event SuperDCATokenOwnershipReturned(address indexed newOwner);

    // Errors
    error NotDynamicFee();
    error InsufficientBalance();
    error ZeroAmount();
    error InvalidPoolFee();
    error PoolMustIncludeSuperDCAToken();

    /**
     * @notice Sets the initial state.
     * @param _poolManager The Uniswap V4 pool manager.
     * @param _superDCAToken The address of the SuperDCAToken contract.
     * @param _developerAddress The address of the Developer.
     * @param _mintRate The number of SuperDCAToken tokens to mint per second.
     */
    constructor(IPoolManager _poolManager, address _superDCAToken, address _developerAddress, uint256 _mintRate)
        BaseHook(_poolManager)
    {
        superDCAToken = _superDCAToken;
        developerAddress = _developerAddress;
        internalFee = INTERNAL_POOL_FEE;
        externalFee = EXTERNAL_POOL_FEE;
        mintRate = _mintRate;
        lastMinted = block.timestamp;

        // Grant the deployer (msg.sender) the default admin role for initial setup and role management
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        // Grant the developer the manager role to control the mint rate and fees
        _grantRole(MANAGER_ROLE, _developerAddress);
    }

    /**
     * @notice Returns the hook permissions.
     * Only beforeAddLiquidity and beforeRemoveLiquidity are enabled.
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
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
     * param sender The address initiating the initialization
     * @param key The pool key containing currency pair and fee information
     * param sqrtPriceX96 The initial sqrt price of the pool
     * @return The function selector
     */
    function _beforeInitialize(address, /* sender */ PoolKey calldata key, uint160 /* sqrtPriceX96 */ )
        internal
        view
        override
        returns (bytes4)
    {
        if (superDCAToken != Currency.unwrap(key.currency0) && superDCAToken != Currency.unwrap(key.currency1)) {
            revert PoolMustIncludeSuperDCAToken();
        }
        return BaseHook.beforeInitialize.selector;
    }

    /**
     * @notice Ensures the pool is initialized with a dynamic fee.
     * @dev Reverts if the pool's fee is not set to the dynamic fee flag.
     * param sender The address initiating the initialization (unused).
     * @param key The pool key containing currency pair and fee information.
     * param sqrtPriceX96 The initial sqrt price of the pool (unused).
     * param tick The initial tick of the pool (unused).
     * @return The function selector.
     */
    function _afterInitialize(address, /* sender */ PoolKey calldata key, uint160, /* sqrtPriceX96 */ int24 /* tick */ )
        internal
        pure
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        return this.afterInitialize.selector;
    }

    /**
     * @notice Calculates and returns the reward amount for a specific pool
     * @dev Only processes rewards for pools that include SuperDCAToken and have the correct fee
     * @param key The pool key containing currency pair and fee information
     * @return Amount of reward tokens to be distributed
     */
    function _getRewardTokens(PoolKey calldata key) internal returns (uint256) {
        // Get token reward info for the non-SuperDCAToken currency
        address otherToken = superDCAToken == Currency.unwrap(key.currency0)
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
        poolManager.sync(Currency.wrap(superDCAToken));
        uint256 rewardAmount = _getRewardTokens(key);
        if (rewardAmount == 0) return;

        // Check if pool has liquidity before proceeding with donation
        uint128 liquidity = IPoolManager(msg.sender).getLiquidity(key.toId());
        if (liquidity == 0) {
            // If no liquidity, try sending everything to developer (do not revert if mint fails)
            _tryMint(developerAddress, rewardAmount);
            return;
        }

        // Split the mint amount between developer and community
        uint256 developerShare = rewardAmount / 2;
        uint256 communityShare = rewardAmount - developerShare;

        // Mint developer share (ignore failure)
        _tryMint(developerAddress, developerShare);

        // Mint community share and donate to pool only if mint succeeds
        if (_tryMint(address(poolManager), communityShare)) {
            // Donate community share to pool
            if (superDCAToken == Currency.unwrap(key.currency0)) {
                IPoolManager(msg.sender).donate(key, communityShare, 0, hookData);
            } else {
                IPoolManager(msg.sender).donate(key, 0, communityShare, hookData);
            }

            // Settle the donation only if mint and donate succeed
            poolManager.settle();
        }

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

    function _beforeSwap(
        address sender,
        PoolKey calldata, /* key */
        IPoolManager.SwapParams calldata, /* params */
        bytes calldata /* hookData */
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        address swapper = IMsgSender(sender).msgSender();
        uint24 fee = isInternalAddress[swapper] ? internalFee : externalFee;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
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
        IERC20(superDCAToken).transferFrom(msg.sender, address(this), amount);

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
        IERC20(superDCAToken).transfer(msg.sender, amount);

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

    /**
     * @notice Allows the manager to update the mint rate.
     * @param newMintRate The new rate at which SuperDCATokens are minted per second.
     */
    function setMintRate(uint256 newMintRate) external onlyRole(MANAGER_ROLE) {
        mintRate = newMintRate;
    }

    /**
     * @notice Allows the admin to update the manager role.
     * @param oldManager The address of the current manager to revoke
     * @param newManager The address of the new manager to grant the role to
     */
    function updateManager(address oldManager, address newManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(MANAGER_ROLE, oldManager);
        grantRole(MANAGER_ROLE, newManager);
    }

    /**
     * @notice Allows the manager to update the internal or external fee.
     * @param _isInternal If true, updates internalFee, otherwise updates externalFee.
     * @param _newFee The new fee value (must be uint24).
     */
    function setFee(bool _isInternal, uint24 _newFee) external onlyRole(MANAGER_ROLE) {
        uint24 oldFee;
        if (_isInternal) {
            oldFee = internalFee;
            internalFee = _newFee;
        } else {
            oldFee = externalFee;
            externalFee = _newFee;
        }
        emit FeeUpdated(_isInternal, oldFee, _newFee);
    }

    /**
     * @notice Allows the manager to mark or unmark an address as internal.
     * @param _user The address to update.
     * @param _isInternal True to mark as internal, false to unmark.
     */
    function setInternalAddress(address _user, bool _isInternal) external onlyRole(MANAGER_ROLE) {
        require(_user != address(0), "Cannot set zero address");
        isInternalAddress[_user] = _isInternal;
        emit InternalAddressUpdated(_user, _isInternal);
    }

    /**
     * @notice Returns the ownership of the Super DCA token back to the admin (DEFAULT_ADMIN_ROLE).
     * @dev The gauge contract must currently be the owner of the token. After the call, the admin
     *      (msg.sender) becomes the new owner. Can only be invoked by an account that has the
     *      DEFAULT_ADMIN_ROLE on the gauge.
     */
    function returnSuperDCATokenOwnership() external onlyRole(DEFAULT_ADMIN_ROLE) {
        ISuperchainERC20(superDCAToken).transferOwnership(msg.sender);
        emit SuperDCATokenOwnershipReturned(msg.sender);
    }

    /**
     * @notice Safely attempts to mint tokens, returning false if the call reverts.
     * @param to The address to mint tokens to.
     * @param amount The amount of tokens to mint.
     * @return success True if minting succeeded, false otherwise.
     */
    function _tryMint(address to, uint256 amount) internal returns (bool success) {
        if (amount == 0) return true;
        try ISuperchainERC20(superDCAToken).mint(to, amount) {
            return true;
        } catch {
            return false;
        }
    }
}
