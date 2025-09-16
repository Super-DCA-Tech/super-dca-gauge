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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "lib/v4-core/test/utils/LiquidityAmounts.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";

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
    using SafeERC20 for IERC20;
    using TickMath for int24;

    IPositionManager public positionManagerV4; // The Uniswap V4 position manager for managing positions
    uint256 public minLiquidity = 1000 * 10 ** 18; // Minimum liquidity for a position to be listed

    // Constants
    uint24 public constant INTERNAL_POOL_FEE = 0; // 0%
    uint24 public constant KEEPER_POOL_FEE = 1000; // 0.10%
    uint24 public constant EXTERNAL_POOL_FEE = 5000; // 0.50%
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

    struct TokenAmounts {
        address token0;
        address token1;
        address dcaToken;
        uint256 dcaAmount;
        uint256 tokAmount;
    }
    // State

    address public superDCAToken;
    address public developerAddress;
    uint24 public internalFee;
    uint24 public externalFee;
    uint256 public mintRate;
    uint256 public lastMinted;
    mapping(address => bool) public isInternalAddress;

    // Keeper staking (separate from reward staking)
    address public keeper;
    uint256 public keeperDeposit;

    // Reward tracking
    uint256 public totalStakedAmount;
    uint256 public rewardIndex = 0;
    mapping(address token => TokenRewardInfo info) public tokenRewardInfos;
    mapping(address user => EnumerableSet.AddressSet stakedTokens) private userStakedTokens;
    mapping(address user => mapping(address token => uint256 amount)) public userStakes;
    mapping(address => bool) public isTokenListed; // Track if a token is listed
    mapping(uint256 => address) public tokenOfNfp; // Stores the token corresponding to a listed NFP

    // Events
    event Staked(address indexed token, address indexed user, uint256 amount);
    event Unstaked(address indexed token, address indexed user, uint256 amount);
    event RewardIndexUpdated(uint256 newIndex);
    event InternalAddressUpdated(address indexed user, bool isInternal);
    event FeeUpdated(bool indexed isInternal, uint24 oldFee, uint24 newFee);
    event SuperDCATokenOwnershipReturned(address indexed newOwner);
    event FeesCollected(
        address indexed recipient, address indexed token0, address indexed token1, uint256 amount0, uint256 amount1
    );
    event TokenListed(address indexed token, uint256 indexed nftId, PoolKey key);
    event KeeperChanged(address indexed oldKeeper, address indexed newKeeper, uint256 deposit);

    // Errors
    error NotDynamicFee();
    error InsufficientBalance();
    error ZeroAmount();
    error InvalidPoolFee();
    error PoolMustIncludeSuperDCAToken();
    error UniswapTokenNotSet();
    error NotTheOwner();
    error IncorrectHookAddress();
    error LowLiquidity();
    error NotFullRangePosition();
    error TokenAlreadyListed();
    error InvalidAddress();

    /**
     * @notice Sets the initial state.
     * @param _poolManager The Uniswap V4 pool manager.
     * @param _superDCAToken The address of the SuperDCAToken contract.
     * @param _developerAddress The address of the Developer.
     * @param _mintRate The number of SuperDCAToken tokens to mint per second.
     */
    constructor(
        IPoolManager _poolManager,
        address _superDCAToken,
        address _developerAddress,
        uint256 _mintRate,
        IPositionManager _positionManagerV4
    ) BaseHook(_poolManager) {
        superDCAToken = _superDCAToken;
        developerAddress = _developerAddress;
        internalFee = INTERNAL_POOL_FEE;
        externalFee = EXTERNAL_POOL_FEE;
        mintRate = _mintRate;
        lastMinted = block.timestamp;
        positionManagerV4 = _positionManagerV4;

        _grantRole(DEFAULT_ADMIN_ROLE, _developerAddress);
        // Grant the developer the manager role to control the mint rate and fees
        _grantRole(MANAGER_ROLE, _developerAddress);
    }

    /**
     * @notice Collects fees from the Uniswap V4 position and transfers them to the recipient
     * @param nfpId The ID of the Non-Fungible Position (NFP) to collect fees from
     * @param recipient The address to which the collected fees will be sent
     * @dev This function collects fees from a specific Uniswap V4 position and transfers
     * the collected fees to the specified recipient
     * and emits an event for the collected fees.
     */
    function collectFees(uint256 nfpId, address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (nfpId == 0) {
            revert UniswapTokenNotSet();
        }
        if (recipient == address(0)) {
            revert InvalidAddress();
        }

        (PoolKey memory key,) = positionManagerV4.getPoolAndPositionInfo(nfpId);
        Currency token0 = key.currency0;
        Currency token1 = key.currency1;

        // tokens balances from recipient before collecting fees
        uint256 balance0Before = IERC20(Currency.unwrap(token0)).balanceOf(recipient);
        uint256 balance1Before = IERC20(Currency.unwrap(token1)).balanceOf(recipient);

        // Encode actions: DECREASE_LIQUIDITY (with zero liquidity) + TAKE_PAIR
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));

        // Prepare parameters and encode them for each action
        bytes[] memory params = new bytes[](2);

        // DECREASE_LIQUIDITY(tokenId, liquidity=0, amount0Min=0, amount1Min=0, hookData)
        params[0] = abi.encode(nfpId, uint256(0), uint128(0), uint128(0), bytes(""));
        // TAKE_PAIR(currency0, currency1, recipient)
        params[1] = abi.encode(token0, token1, recipient);

        // Execute the actions by calling the PositionManager
        uint256 deadline = block.timestamp + 60;

        positionManagerV4.modifyLiquidities(abi.encode(actions, params), deadline);

        // balances after collecting fees
        uint256 balance0After = IERC20(Currency.unwrap(token0)).balanceOf(recipient);
        uint256 balance1After = IERC20(Currency.unwrap(token1)).balanceOf(recipient);

        // Calculate the collected amounts
        uint256 collectedAmount0 = balance0After - balance0Before;
        uint256 collectedAmount1 = balance1After - balance1Before;

        // Emit event for collected fees

        emit FeesCollected(
            recipient, Currency.unwrap(token0), Currency.unwrap(token1), collectedAmount0, collectedAmount1
        );
    }

    /**
     *
     * @param nftId the Non-Fungible Position (NFP) ID to list
     * @param key the PoolKey of the position to list
     * @notice Lists a Non-Fungible Position (NFP) for DCA trading
     * @dev This function allows users to list their NFPs for DCA trading by providing
     * the NFP ID and the PoolKey. It checks if the token is already listed,
     * verifies the position's liquidity, and ensures the pool fee is a dynamic fee.
     * It also checks that the position is a full range position.
     * @dev The position must be a full range position, meaning it covers the entire tick range.
     * @dev The function transfers the NFP ownership from the user to this contract.
     */
    function list(uint256 nftId, PoolKey calldata key) external {
        PoolId poolId = key.toId();

        // check that the hooks address is this contrat address
        if (key.hooks != IHooks(address(this))) {
            revert IncorrectHookAddress();
        }

        // check that the nftId is not zero
        if (nftId == 0) {
            revert UniswapTokenNotSet();
        }

        // check that the pool fee is dyamic fee value
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();

        //check that the position is full range position
        PositionInfo positionInfo = positionManagerV4.positionInfo(nftId);
        int24 tickLower = positionInfo.tickLower();
        int24 tickUpper = positionInfo.tickUpper();

        if (
            tickLower != TickMath.minUsableTick(key.tickSpacing) && tickUpper != TickMath.maxUsableTick(key.tickSpacing) // I think this is the best way to check if the position is full range. check it please!!!
        ) {
            revert NotFullRangePosition();
        }
        // liquidity amounts
        uint128 liquidity = positionManagerV4.getPositionLiquidity(nftId);

        (uint256 amount0, uint256 amount1) = _getAmounts(poolId, tickLower, tickUpper, liquidity);
        TokenAmounts memory ta; // Token amounts to be used for DCA trading
        ta.token0 = Currency.unwrap(key.currency0);
        ta.token1 = Currency.unwrap(key.currency1);

        address tok; // The token that is not the SuperDCAToken

        // check that DCA token is one of the tokens in the pool and set the token amounts accordingly
        if (ta.token0 == address(superDCAToken)) {
            ta.dcaToken = ta.token0;
            tok = ta.token1;
            ta.dcaAmount = amount0;
            ta.tokAmount = amount1;
        } else if (ta.token1 == address(superDCAToken)) {
            ta.dcaToken = ta.token1;
            tok = ta.token0;
            ta.dcaAmount = amount1;
            ta.tokAmount = amount0;
        } else {
            revert PoolMustIncludeSuperDCAToken();
        }

        // check that the position has liquidity greater than 1000 DCA tokens
        if (ta.dcaAmount < minLiquidity) {
            revert LowLiquidity();
        }

        // check that the token is not already listed
        if (isTokenListed[tok]) {
            revert TokenAlreadyListed();
        }
        isTokenListed[tok] = true;
        tokenOfNfp[nftId] = tok;

        // transfer the NFP ownership from user to this contract

        IERC721(address(positionManagerV4)).transferFrom(msg.sender, address(this), nftId);

        emit TokenListed(tok, nftId, key);
    }

    function setMinimumLiquidity(uint256 _minLiquidity) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minLiquidity = _minLiquidity;
    }

    /**
     *
     * @param poolId the PoolId of the Uniswap V4 pool
     * @param tickLower the lower tick of the position
     * @param tickUpper the upper tick of the position
     * @param liquidity the liquidity of the position
     * @return amount0 The amount of token0 that would be received for the given liquidity
     * @return amount1 The amount of token1 that would be received for the given liquidity
     */
    function _getAmounts(PoolId poolId, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        return (LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, liquidity));
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
        uint256 rewardAmount = Math.mulDiv(tokenInfo.stakedAmount, rewardIndex - tokenInfo.lastRewardIndex, 1e18);
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
        uint24 fee;

        if (isInternalAddress[swapper]) {
            fee = internalFee;
        } else if (swapper == keeper) {
            fee = KEEPER_POOL_FEE;
        } else {
            fee = externalFee;
        }

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
        if (amount == 0) revert ZeroAmount();
        if (amount <= keeperDeposit) revert InsufficientBalance();

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
     * @notice Updates the global reward index based on elapsed time and mint rate
     * @dev The reward index increases proportionally to the time passed and total staked amount
     */
    function _updateRewardIndex() internal {
        if (totalStakedAmount == 0) return;

        uint256 currentTime = block.timestamp;
        uint256 elapsed = currentTime - lastMinted;

        if (elapsed > 0) {
            uint256 mintAmount = elapsed * mintRate;
            rewardIndex += Math.mulDiv(mintAmount, 1e18, totalStakedAmount);
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
            currentIndex += Math.mulDiv(mintAmount, 1e18, totalStakedAmount);
        }

        return Math.mulDiv(info.stakedAmount, (currentIndex - info.lastRewardIndex), 1e18);
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
