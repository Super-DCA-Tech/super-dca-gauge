// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {BaseHook} from "v4-periphery/utils/BaseHook.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISuperchainERC20} from "./interfaces/ISuperchainERC20.sol";
import {IMsgSender} from "./interfaces/IMsgSender.sol";
import {ISuperDCAStaking} from "./interfaces/ISuperDCAStaking.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {ISuperDCAListing} from "./interfaces/ISuperDCAListing.sol";

/**
 * @title SuperDCAGauge
 * @notice A Uniswap V4 pool hook that implements dynamic fee management, keeper mechanisms, and reward distribution.
 * @dev This contract serves as a central hook for DCA (Dollar Cost Averaging) pools, providing:
 *      - Dynamic fee structure based on user type (internal, external, keeper)
 *      - Keeper deposit system with king-of-the-hill replacement mechanism
 *      - Integration with external staking contract for reward distribution
 *      - Pool validation to ensure only SuperDCAToken pairs are used
 *      - Fee revenue distribution between community (via pool donations) and developer
 *
 * Architecture:
 * - Hook Integration: Implements Uniswap V4 hooks for beforeInitialize, afterInitialize,
 *   beforeAddLiquidity, beforeRemoveLiquidity, and beforeSwap
 * - Fee Management: Three-tier fee structure (internal: 0%, keeper: 0.10%, external: 0.50%)
 * - Keeper System: Users can deposit DCA tokens to become keeper and get reduced fees
 * - Reward Distribution: 50/50 split between community pool donations and developer payments
 * - Access Control: Role-based permissions for admin operations and fee management
 *
 * Security Features:
 * - Pool validation ensures only SuperDCAToken pairs can use this hook
 * - Dynamic fee enforcement prevents bypassing fee structure
 * - Safe minting with failure handling to prevent DoS attacks
 * - Proper settlement and sync patterns for Uniswap V4 integration
 */
contract SuperDCAGauge is BaseHook, AccessControl {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPositionManager public positionManagerV4; // The Uniswap V4 position manager for managing positions
    ISuperDCAListing public listing; // External listing module

    // Constants
    uint24 public constant INTERNAL_POOL_FEE = 0; // 0%
    uint24 public constant KEEPER_POOL_FEE = 1000; // 0.10%
    uint24 public constant EXTERNAL_POOL_FEE = 5000; // 0.50%
    int24 public constant REQUIRED_TICK_SPACING = 10; // Required tick spacing to prevent duplicate pools
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /**
     * @notice Enum defining the three types of fees charged to different user categories.
     * @dev Used in setFee function to specify which fee type to update.
     */
    enum FeeType {
        INTERNAL, // Fee for whitelisted internal addresses (typically 0%)
        EXTERNAL, // Fee for regular external users (typically 0.50%)
        KEEPER // Fee for the current keeper (typically 0.10%)

    }

    /**
     * @notice Structure for holding token addresses and amounts in DCA operations.
     * @dev Used internally for organizing token data during transactions.
     */
    struct TokenAmounts {
        address token0; // First token in the pair
        address token1; // Second token in the pair
        address dcaToken; // The DCA token address
        uint256 dcaAmount; // Amount of DCA tokens
        uint256 tokAmount; // Amount of the other token
    }
    // ============ State Variables ============

    /// @notice The address of the SuperDCA token contract.
    /// @dev This token must be one of the currencies in any pool using this hook.
    address public superDCAToken;

    /// @notice The address that receives developer fees from reward distributions.
    /// @dev Set during construction and can be updated via access control.
    address public developerAddress;

    /// @notice Fee charged to whitelisted internal addresses (in basis points).
    /// @dev Typically set to 0 to incentivize internal usage.
    uint24 public internalFee;

    /// @notice Fee charged to external users (in basis points).
    /// @dev Default is 5000 (0.50%) for regular users.
    uint24 public externalFee;

    /// @notice Fee charged to the current keeper (in basis points).
    /// @dev Default is 1000 (0.10%) as an incentive for keeper services.
    uint24 public keeperFee;

    /// @notice Mapping to track which addresses are marked as internal for fee purposes.
    /// @dev Internal addresses pay reduced fees to encourage platform usage.
    mapping(address => bool) public isInternalAddress;

    /// @notice The current keeper address who has deposited the highest amount.
    /// @dev Keeper gets reduced fees and can be replaced by higher deposits.
    address public keeper;

    /// @notice The amount of DCA tokens deposited by the current keeper.
    /// @dev Used in the king-of-the-hill mechanism for keeper replacement.
    uint256 public keeperDeposit;

    /// @notice External staking contract that manages reward calculations and distributions.
    /// @dev Called during liquidity operations to accrue and distribute rewards.
    ISuperDCAStaking public staking;

    // ============ Events ============

    /// @notice Emitted when an address's internal status is updated.
    /// @param user The address whose status was changed.
    /// @param isInternal True if the address is now internal, false otherwise.
    event InternalAddressUpdated(address indexed user, bool isInternal);

    /// @notice Emitted when a fee type is updated by the manager.
    /// @param feeType The type of fee that was updated (INTERNAL, EXTERNAL, or KEEPER).
    /// @param oldFee The previous fee value in basis points.
    /// @param newFee The new fee value in basis points.
    event FeeUpdated(FeeType indexed feeType, uint24 oldFee, uint24 newFee);

    /// @notice Emitted when SuperDCA token ownership is transferred back to admin.
    /// @param newOwner The address that received ownership of the SuperDCA token.
    event SuperDCATokenOwnershipReturned(address indexed newOwner);

    /// @notice Emitted when the keeper changes through the deposit mechanism.
    /// @param oldKeeper The address of the previous keeper (zero address if none).
    /// @param newKeeper The address of the new keeper.
    /// @param deposit The amount of DCA tokens deposited by the new keeper.
    event KeeperChanged(address indexed oldKeeper, address indexed newKeeper, uint256 deposit);

    /// @notice Emitted when the staking contract address is updated.
    /// @param oldStaking The address of the previous staking contract.
    /// @param newStaking The address of the new staking contract.
    event StakingUpdated(address indexed oldStaking, address indexed newStaking);

    /// @notice Emitted when the listing contract address is updated.
    /// @param oldListing The address of the previous listing contract.
    /// @param newListing The address of the new listing contract.
    event ListingUpdated(address indexed oldListing, address indexed newListing);

    // ============ Custom Errors ============

    /// @notice Thrown when a pool is not configured with dynamic fees.
    error SuperDCAGauge__NotDynamicFee();

    /// @notice Thrown when a keeper deposit amount is insufficient to replace current keeper.
    error SuperDCAGauge__InsufficientBalance();

    /// @notice Thrown when a zero amount is provided where a positive amount is required.
    error SuperDCAGauge__ZeroAmount();

    /// @notice Thrown when an invalid pool fee configuration is detected.
    error SuperDCAGauge__InvalidPoolFee();

    /// @notice Thrown when a pool doesn't include the SuperDCA token as one of its currencies.
    error SuperDCAGauge__PoolMustIncludeSuperDCAToken();

    /// @notice Thrown when the Uniswap token address is not properly set.
    error SuperDCAGauge__UniswapTokenNotSet();

    /// @notice Thrown when caller is not the expected owner.
    error SuperDCAGauge__NotTheOwner();

    /// @notice Thrown when an invalid address is provided.
    error SuperDCAGauge__InvalidAddress();

    /// @notice Thrown when a zero address is provided where a valid address is required.
    error SuperDCAGauge__ZeroAddress();

    /// @notice Thrown when a pool's tick spacing is not the required value.
    error SuperDCAGauge__InvalidTickSpacing();

    /**
     * @notice Initializes the SuperDCAGauge hook with core addresses and default fee structure.
     * @dev Sets up access control roles and default fee values. The developer address receives
     *      both DEFAULT_ADMIN_ROLE and MANAGER_ROLE permissions.
     * @param _poolManager The Uniswap V4 pool manager contract.
     * @param _superDCAToken The address of the SuperDCA token contract.
     * @param _developerAddress The address that will receive developer fees and admin permissions.
     * @param _positionManagerV4 The Uniswap V4 position manager for handling positions.
     */
    constructor(
        IPoolManager _poolManager,
        address _superDCAToken,
        address _developerAddress,
        IPositionManager _positionManagerV4
    ) BaseHook(_poolManager) {
        superDCAToken = _superDCAToken;
        developerAddress = _developerAddress;
        internalFee = INTERNAL_POOL_FEE;
        externalFee = EXTERNAL_POOL_FEE;
        keeperFee = KEEPER_POOL_FEE;
        positionManagerV4 = _positionManagerV4;

        _grantRole(DEFAULT_ADMIN_ROLE, _developerAddress);
        // Grant the developer the manager role to control the mint rate and fees
        _grantRole(MANAGER_ROLE, _developerAddress);
    }

    /**
     * @notice Sets the external staking contract address for reward calculations.
     * @dev Only callable by DEFAULT_ADMIN_ROLE. The staking contract handles reward
     *      accrual calculations and distribution logic.
     * @param stakingAddr The address of the deployed staking contract.
     */
    function setStaking(address stakingAddr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (stakingAddr == address(0)) revert SuperDCAGauge__ZeroAddress();
        address oldStaking = address(staking);
        staking = ISuperDCAStaking(stakingAddr);
        emit StakingUpdated(oldStaking, stakingAddr);
    }

    /**
     * @notice Sets the external listing contract used for token listing queries.
     * @dev Only callable by DEFAULT_ADMIN_ROLE. The listing contract determines
     *      which tokens are approved for DCA operations.
     * @param _listing The address of the listing contract.
     */
    function setListing(address _listing) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldListing = address(listing);
        listing = ISuperDCAListing(_listing);
        emit ListingUpdated(oldListing, _listing);
    }

    /**
     * @notice Checks if a token is approved for DCA operations via the listing contract.
     * @dev Returns false if no listing contract is set. Used by external contracts
     *      to validate token eligibility before operations.
     * @param token The token address to check.
     * @return True if the token is listed and approved for DCA, false otherwise.
     */
    function isTokenListed(address token) external view returns (bool) {
        if (address(listing) == address(0)) return false;
        return listing.isTokenListed(token);
    }

    /**
     * @notice Returns the hook permissions required by this contract.
     * @dev Enables beforeInitialize, afterInitialize, beforeAddLiquidity,
     *      beforeRemoveLiquidity, and beforeSwap hooks. These are necessary for:
     *      - Pool validation during initialization
     *      - Dynamic fee enforcement
     *      - Reward distribution during liquidity operations
     * @return Hooks.Permissions struct with enabled hook flags.
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
     * @notice Validates that pools using this hook include the SuperDCA token and have the required tick spacing.
     * @dev Called before pool initialization to ensure only valid DCA pools use this hook.
     *      Prevents misconfiguration by requiring one currency to be the SuperDCA token.
     *      Also restricts tick spacing to exactly 10 to prevent duplicate pools with different tick spacing values.
     * @param key The pool key containing currency pair and fee information.
     * @return The function selector to confirm successful validation.
     */
    function _beforeInitialize(address, /* sender */ PoolKey calldata key, uint160 /* sqrtPriceX96 */ )
        internal
        view
        override
        returns (bytes4)
    {
        if (superDCAToken != Currency.unwrap(key.currency0) && superDCAToken != Currency.unwrap(key.currency1)) {
            revert SuperDCAGauge__PoolMustIncludeSuperDCAToken();
        }
        if (key.tickSpacing != REQUIRED_TICK_SPACING) {
            revert SuperDCAGauge__InvalidTickSpacing();
        }
        return BaseHook.beforeInitialize.selector;
    }

    /**
     * @notice Ensures the pool is configured with dynamic fees after initialization.
     * @dev Called after pool initialization to verify the pool supports dynamic fee changes.
     *      This is required for the hook to properly adjust fees based on user type.
     * @param key The pool key containing currency pair and fee information.
     * @return The function selector to confirm successful validation.
     */
    function _afterInitialize(address, /* sender */ PoolKey calldata key, uint160, /* sqrtPriceX96 */ int24 /* tick */ )
        internal
        pure
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert SuperDCAGauge__NotDynamicFee();
        return this.afterInitialize.selector;
    }

    /**
     * @notice Handles reward accrual and distribution during liquidity operations.
     * @dev This function implements the core reward distribution logic:
     *      1. Syncs the pool manager with the SuperDCA token state
     *      2. Identifies the non-DCA token for reward calculation
     *      3. Accrues rewards via the external staking contract
     *      4. Distributes rewards 50/50 between developer and community
     *      5. Donates community share to the pool if liquidity exists
     *
     *      If no pool liquidity exists, all rewards go to developer to prevent
     *      donation failures. Minting failures are handled gracefully to prevent DoS.
     * @param key The pool key identifying the Uniswap V4 pool.
     * @param hookData Additional data passed to the hook for donation operations.
     */
    function _handleDistributionAndSettlement(PoolKey calldata key, bytes calldata hookData) internal {
        // Must sync the pool manager to the token before distributing tokens
        poolManager.sync(Currency.wrap(superDCAToken));

        // Derive the non-DCA token for accrual calculation
        // The staking contract uses this to determine reward amounts
        address otherToken = superDCAToken == Currency.unwrap(key.currency0)
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);

        // Calculate pending rewards from the external staking contract
        uint256 rewardAmount = staking.accrueReward(otherToken);
        if (rewardAmount == 0) return;

        // Check if pool has liquidity before proceeding with donation
        uint128 liquidity = IPoolManager(msg.sender).getLiquidity(key.toId());
        if (liquidity == 0) {
            // If no liquidity, try sending everything to developer (do not revert if mint fails)
            _tryMint(developerAddress, rewardAmount);
            return;
        }

        // Split the mint amount between developer and community (50/50)
        uint256 developerShare = rewardAmount / 2;
        uint256 communityShare = rewardAmount - developerShare;

        // Mint developer share (ignore failure)
        _tryMint(developerAddress, developerShare);

        // Mint community share and donate to pool only if mint succeeds
        // This prevents donation of tokens that don't exist
        if (_tryMint(address(poolManager), communityShare)) {
            // Donate community share to pool
            if (superDCAToken == Currency.unwrap(key.currency0)) {
                IPoolManager(msg.sender).donate(key, communityShare, 0, hookData);
            } else {
                IPoolManager(msg.sender).donate(key, 0, communityShare, hookData);
            }

            // Settle the donation to complete the transaction
            poolManager.settle();
        }

        /// @dev: At this point, there are DCA tokens left in the hook for the other pools.
    }

    /**
     * @notice Hook called before liquidity is added to a pool.
     * @dev Triggers reward distribution before the liquidity operation to ensure
     *      accurate reward calculations based on current pool state.
     * @param key The pool key for the liquidity operation.
     * @param hookData Additional data passed to the hook.
     * @return The function selector to confirm successful execution.
     */
    function _beforeAddLiquidity(
        address, // sender
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata, // params
        bytes calldata hookData
    ) internal override returns (bytes4) {
        _handleDistributionAndSettlement(key, hookData);
        return BaseHook.beforeAddLiquidity.selector;
    }

    /**
     * @notice Hook called before liquidity is removed from a pool.
     * @dev Triggers reward distribution before the liquidity operation to ensure
     *      rewards are properly allocated before pool state changes.
     * @param key The pool key for the liquidity operation.
     * @param hookData Additional data passed to the hook.
     * @return The function selector to confirm successful execution.
     */
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
     * @notice Hook called before each swap to determine the appropriate fee.
     * @dev Implements a three-tier fee structure based on the swapper's status:
     *      - Internal addresses: Pay internalFee (typically 0%)
     *      - Current keeper: Pays keeperFee (typically 0.10%)
     *      - External users: Pay externalFee (typically 0.50%)
     *
     *      The function uses IMsgSender to get the actual message sender when called
     *      through intermediary contracts like routers or position managers.
     * @param sender The address that initiated the swap (may be a router/manager).
     * @return selector The function selector for successful execution.
     * @return delta Zero delta as this hook doesn't modify swap amounts.
     * @return fee The calculated fee with override flag set.
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata, /* key */
        IPoolManager.SwapParams calldata, /* params */
        bytes calldata /* hookData */
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        // Get the actual message sender (may differ from 'sender' when using routers)
        address swapper = IMsgSender(sender).msgSender();
        uint24 fee;

        // Determine fee tier based on swapper status
        if (isInternalAddress[swapper]) {
            fee = internalFee; // Typically 0% for internal addresses
        } else if (swapper == keeper) {
            fee = keeperFee; // Typically 0.10% for keeper
        } else {
            fee = externalFee; // Typically 0.50% for external users
        }

        // Return with override flag to ensure our fee is used
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /**
     * @notice Allows users to become the keeper by depositing more DCA tokens than the current keeper
     * @dev Implements king-of-the-hill mechanism where higher deposits replace current keeper
     * @dev This function is protected against reentrancy by the order of operations:
     *      1. Validate inputs and transfer new deposit first
     *      2. Refund previous keeper (external call)
     *      3. Update state variables
     * @param amount The amount of DCA tokens to deposit to become keeper
     */
    function becomeKeeper(uint256 amount) external {
        if (amount == 0) revert SuperDCAGauge__ZeroAmount();
        if (amount <= keeperDeposit) revert SuperDCAGauge__InsufficientBalance();

        address oldKeeper = keeper;
        uint256 oldDeposit = keeperDeposit;

        // Transfer new deposit from user
        IERC20(superDCAToken).transferFrom(msg.sender, address(this), amount);

        // Refund previous keeper if one exists
        if (oldKeeper != address(0) && oldDeposit > 0) {
            IERC20(superDCAToken).transfer(oldKeeper, oldDeposit);
        }

        // Set new keeper
        keeper = msg.sender;
        keeperDeposit = amount;

        emit KeeperChanged(oldKeeper, msg.sender, amount);
    }

    /**
     * @notice Returns the current keeper information
     * @return currentKeeper The address of the current keeper
     * @return currentDeposit The amount deposited by the current keeper
     */
    function getKeeperInfo() external view returns (address currentKeeper, uint256 currentDeposit) {
        return (keeper, keeperDeposit);
    }

    /**
     * @notice Updates the manager role by revoking from old address and granting to new address.
     * @dev Only callable by DEFAULT_ADMIN_ROLE. The manager role allows setting fees and
     *      internal address designations.
     * @param oldManager The address of the current manager to revoke the role from.
     * @param newManager The address of the new manager to grant the role to.
     */
    function updateManager(address oldManager, address newManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(MANAGER_ROLE, oldManager);
        grantRole(MANAGER_ROLE, newManager);
    }

    /**
     * @notice Updates one of the three fee types (internal, external, or keeper).
     * @dev Only callable by MANAGER_ROLE. Fees are specified in basis points
     *      (e.g., 5000 = 0.50%). Emits FeeUpdated event with old and new values.
     * @param _feeType The type of fee to update (INTERNAL, EXTERNAL, or KEEPER).
     * @param _newFee The new fee value in basis points.
     */
    function setFee(FeeType _feeType, uint24 _newFee) external onlyRole(MANAGER_ROLE) {
        uint24 oldFee;
        if (_feeType == FeeType.INTERNAL) {
            oldFee = internalFee;
            internalFee = _newFee;
        } else if (_feeType == FeeType.EXTERNAL) {
            oldFee = externalFee;
            externalFee = _newFee;
        } else if (_feeType == FeeType.KEEPER) {
            oldFee = keeperFee;
            keeperFee = _newFee;
        }
        emit FeeUpdated(_feeType, oldFee, _newFee);
    }

    /**
     * @notice Marks or unmarks an address as internal for fee calculation purposes.
     * @dev Only callable by MANAGER_ROLE. Internal addresses typically pay reduced
     *      or zero fees to incentivize platform usage. Reverts on zero address.
     * @param _user The address to update.
     * @param _isInternal True to mark as internal, false to unmark.
     */
    function setInternalAddress(address _user, bool _isInternal) external onlyRole(MANAGER_ROLE) {
        if (_user == address(0)) revert SuperDCAGauge__ZeroAddress();
        isInternalAddress[_user] = _isInternal;
        emit InternalAddressUpdated(_user, _isInternal);
    }

    /**
     * @notice Transfers ownership of the SuperDCA token back to the caller.
     * @dev Only callable by DEFAULT_ADMIN_ROLE. Used when the gauge contract initially
     *      owns the SuperDCA token but ownership needs to be returned to the admin for
     *      configuration or other administrative purposes.
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
