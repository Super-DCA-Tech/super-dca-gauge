// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "lib/v4-core/test/utils/LiquidityAmounts.sol";

import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {ISuperDCAListing} from "./interfaces/ISuperDCAListing.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";

/**
 * @title SuperDCAListing
 * @notice Manages token listing for Super DCA by validating and taking custody of Uniswap V4 NFT positions.
 * @dev This contract implements a token listing system where tokens become eligible for DCA operations
 *      by depositing qualifying Uniswap V4 NFT positions. The contract enforces strict validation:
 *
 *      Listing Requirements:
 *      - Position must be full-range (min to max usable ticks)
 *      - Pool must pair the target token with SUPER_DCA_TOKEN
 *      - Pool must use the configured gauge hook (SuperDCAGauge)
 *      - SuperDCA token liquidity must meet minimum threshold
 *      - Token cannot already be listed
 *
 *      Architecture:
 *      - Uses Ownable2Step for secure ownership transfers
 *      - Integrates with Uniswap V4 PoolManager and PositionManager
 *      - Validates pool configuration and position parameters
 *      - Enables fee collection for deposited positions
 *
 *      Security Features:
 *      - Pool key validation prevents manipulation
 *      - Hook address enforcement ensures gauge integration
 *      - Full-range requirement prevents partial liquidity gaming
 *      - Minimum liquidity threshold ensures meaningful listings
 */
contract SuperDCAListing is ISuperDCAListing, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ============ Immutable Configuration ============

    /// @notice The Uniswap V4 pool manager contract for pool state queries and validation.
    /// @dev Used to retrieve pool information and validate pool states.
    IPoolManager public immutable POOL_MANAGER;

    /// @notice The Uniswap V4 position manager contract for NFT position operations.
    /// @dev Used to query position details, transfer custody, and collect fees.
    IPositionManager public immutable POSITION_MANAGER_V4;

    /// @notice The SuperDCA token that must be paired in all listed pools.
    /// @dev Every listed token must have a pool that pairs with this token.
    address public immutable SUPER_DCA_TOKEN;

    // ============ Mutable Configuration ============

    /// @notice The required hook address that must be present in listed pools.
    /// @dev Typically set to the SuperDCAGauge address to ensure proper integration.
    IHooks public expectedHooks;

    /// @notice The minimum SuperDCA token liquidity required for listing eligibility.
    /// @dev Prevents spam listings with insignificant liquidity amounts.
    uint256 public minLiquidity = 1000 * 10 ** 18;

    // ============ Listing State ============

    /// @notice Tracks which tokens have been successfully listed for DCA operations.
    /// @dev Maps token address to listing status (true = listed, false = not listed).
    mapping(address token => bool listed) public override isTokenListed;

    /// @notice Maps NFT position IDs to their corresponding listed token addresses.
    /// @dev Used to track which positions are held by this contract for each token.
    mapping(uint256 nfpId => address token) public override tokenOfNfp;

    // ============ Events ============

    /// @notice Emitted when a token is successfully listed through NFT position deposit.
    /// @param token The token address that was listed for DCA operations.
    /// @param nftId The Uniswap V4 NFT position ID that was deposited.
    /// @param key The complete pool key for the position (currencies, fee, tickSpacing, hooks).
    event TokenListed(address indexed token, uint256 indexed nftId, PoolKey key);

    /// @notice Emitted when the minimum liquidity requirement is updated by the owner.
    /// @param oldMin The previous minimum liquidity requirement.
    /// @param newMin The new minimum liquidity requirement.
    event MinimumLiquidityUpdated(uint256 oldMin, uint256 newMin);

    /// @notice Emitted when the expected hook address is updated by the owner.
    /// @param oldHook The previous hook address.
    /// @param newHook The new required hook address for listings.
    event HookAddressSet(address indexed oldHook, address indexed newHook);

    /// @notice Emitted when fees are collected from a listed position.
    /// @param recipient The address that received the collected fees.
    /// @param token0 The first token in the pool pair.
    /// @param token1 The second token in the pool pair.
    /// @param amount0 The amount of token0 fees collected.
    /// @param amount1 The amount of token1 fees collected.
    event FeesCollected(
        address indexed recipient, address indexed token0, address indexed token1, uint256 amount0, uint256 amount1
    );

    // ============ Custom Errors ============

    /// @notice Thrown when an NFT ID is zero or when required addresses are not properly set.
    error SuperDCAListing__UniswapTokenNotSet();

    /// @notice Thrown when the pool's hook address doesn't match the required gauge hook.
    error SuperDCAListing__IncorrectHookAddress();

    /// @notice Thrown when the SuperDCA token liquidity is below the minimum requirement.
    error SuperDCAListing__LowLiquidity();

    /// @notice Thrown when the NFT position is not full-range for the pool's tick spacing.
    error SuperDCAListing__NotFullRangePosition();

    /// @notice Thrown when attempting to list a token that has already been listed.
    error SuperDCAListing__TokenAlreadyListed();

    /// @notice Thrown when a zero address is provided where a valid address is required.
    error SuperDCAListing__ZeroAddress();

    /// @notice Thrown when an invalid address is provided for operations requiring valid addresses.
    error SuperDCAListing__InvalidAddress();

    /// @notice Thrown when the provided pool key doesn't match the NFT position's actual key.
    error SuperDCAListing__MismatchedPoolKey();

    /**
     * @notice Initializes the SuperDCAListing contract with core addresses and configuration.
     * @dev Sets up the contract with immutable addresses and transfers ownership to the admin.
     *      The expected hooks address can be updated later by the owner.
     * @param _superDCAToken The address of the SuperDCA ERC20 token that must be in all listed pools.
     * @param _poolManager The Uniswap V4 pool manager contract address.
     * @param _positionManagerV4 The Uniswap V4 position manager contract address.
     * @param _admin The address that will become the owner of this contract.
     * @param _expectedHooks The initial hook address required for valid pool listings.
     */
    constructor(
        address _superDCAToken,
        IPoolManager _poolManager,
        IPositionManager _positionManagerV4,
        address _admin,
        IHooks _expectedHooks
    ) Ownable(_admin) {
        if (_superDCAToken == address(0)) revert SuperDCAListing__ZeroAddress();
        SUPER_DCA_TOKEN = _superDCAToken;
        POOL_MANAGER = _poolManager;
        POSITION_MANAGER_V4 = _positionManagerV4;
        expectedHooks = _expectedHooks;
    }

    /**
     * @notice Updates the required hook address for new token listings.
     * @dev Only callable by the contract owner. This allows updating the gauge address
     *      if needed without redeploying the listing contract.
     * @param _newHook The new hook address that must be present in listed pools.
     */
    function setHookAddress(IHooks _newHook) external {
        _checkOwner();
        emit HookAddressSet(address(expectedHooks), address(_newHook));
        expectedHooks = _newHook;
    }

    /**
     * @notice Updates the minimum SuperDCA token liquidity required for token listings.
     * @dev Only callable by the contract owner. Used to adjust listing requirements
     *      based on market conditions or policy changes.
     * @param _minLiquidity The new minimum liquidity threshold in SuperDCA tokens.
     */
    function setMinimumLiquidity(uint256 _minLiquidity) external override {
        _checkOwner();
        uint256 old = minLiquidity;
        minLiquidity = _minLiquidity;
        emit MinimumLiquidityUpdated(old, _minLiquidity);
    }

    /**
     * @notice Lists a token for DCA operations by validating and taking custody of a Uniswap V4 NFT position.
     * @dev On successful validation, transfers NFT custody to this contract and marks
     *      the token as listed for DCA operations.
     * @param nftId The Uniswap V4 NFT position ID to use for listing.
     * @param providedKey The pool key that must match the position's actual configuration.
     */
    function list(uint256 nftId, PoolKey calldata providedKey) external override {
        // Verify NFT ID is non-zero
        if (nftId == 0) revert SuperDCAListing__UniswapTokenNotSet();

        // Retrieve actual pool key from position manager and validate it matches
        // the caller's provided key to prevent manipulation or misconfiguration
        (PoolKey memory key,) = POSITION_MANAGER_V4.getPoolAndPositionInfo(nftId);
        if (
            Currency.unwrap(key.currency0) != Currency.unwrap(providedKey.currency0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(providedKey.currency1) || key.fee != providedKey.fee
                || key.tickSpacing != providedKey.tickSpacing || address(key.hooks) != address(providedKey.hooks)
        ) {
            revert SuperDCAListing__MismatchedPoolKey();
        }

        // Confirm pool uses the required hook address
        // This ensures proper integration with the DCA system
        if (address(key.hooks) != address(expectedHooks)) revert SuperDCAListing__IncorrectHookAddress();

        // Ensure position is full-range (min to max usable ticks)
        // This prevents gaming with partial liquidity ranges
        {
            PositionInfo _pi = POSITION_MANAGER_V4.positionInfo(nftId);
            int24 _tickLower = _pi.tickLower();
            int24 _tickUpper = _pi.tickUpper();

            if (
                _tickLower != TickMath.minUsableTick(key.tickSpacing)
                    || _tickUpper != TickMath.maxUsableTick(key.tickSpacing)
            ) {
                revert SuperDCAListing__NotFullRangePosition();
            }

            // Calculate token amounts from the position's liquidity
            uint128 _liquidity = POSITION_MANAGER_V4.getPositionLiquidity(nftId);
            (uint256 amount0, uint256 amount1) = _getAmountsForKey(key, _tickLower, _tickUpper, _liquidity);

            // Determine which token is being listed and validate SuperDCA liquidity amount
            address listedToken;
            uint256 dcaAmount;
            if (Currency.unwrap(key.currency0) == SUPER_DCA_TOKEN) {
                listedToken = Currency.unwrap(key.currency1);
                dcaAmount = amount0;
            } else {
                listedToken = Currency.unwrap(key.currency0);
                dcaAmount = amount1;
            }

            // Check that the non-DCA token isn't already listed
            if (isTokenListed[listedToken]) revert SuperDCAListing__TokenAlreadyListed();

            // Validate SuperDCA token liquidity meets minimum requirement
            if (dcaAmount < minLiquidity) revert SuperDCAListing__LowLiquidity();

            // Update listing state
            isTokenListed[listedToken] = true;
            tokenOfNfp[nftId] = listedToken;
        }

        // Transfer NFT custody to this contract
        IERC721(address(POSITION_MANAGER_V4)).transferFrom(msg.sender, address(this), nftId);
        emit TokenListed(tokenOfNfp[nftId], nftId, key);
    }

    /**
     * @notice Calculates token amounts for a liquidity position based on current pool price.
     * @dev Uses Uniswap V4's standard math libraries to convert liquidity to token amounts.
     *      The calculation depends on the current pool price (sqrtPriceX96) and the
     *      position's tick range. For full-range positions, this gives the exact
     *      token amounts that would be withdrawn if the position were closed.
     * @param key The pool key containing currency and fee information.
     * @param tickLower The lower tick of the position (should be min usable tick).
     * @param tickUpper The upper tick of the position (should be max usable tick).
     * @param liquidity The position's liquidity amount.
     * @return amount0 The calculated amount of currency0 in the position.
     * @return amount1 The calculated amount of currency1 in the position.
     */
    function _getAmountsForKey(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        return (LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, liquidity));
    }

    /**
     * @notice Collects accumulated fees from a listed NFT position and transfers them to a recipient.
     * @dev Only callable by the contract owner. Uses Uniswap V4's DECREASE_LIQUIDITY and TAKE_PAIR
     *      actions with zero liquidity to collect fees without removing position liquidity.
     * @param nfpId The NFT position ID to collect fees from.
     * @param recipient The address that will receive the collected fees.
     */
    function collectFees(uint256 nfpId, address recipient) external override {
        _checkOwner();

        // Validate the NFT ID and recipient address
        if (nfpId == 0) revert SuperDCAListing__UniswapTokenNotSet();
        if (recipient == address(0)) revert SuperDCAListing__InvalidAddress();

        // Retrieve the position's pool information
        (PoolKey memory key,) = POSITION_MANAGER_V4.getPoolAndPositionInfo(nfpId);
        Currency token0 = key.currency0;
        Currency token1 = key.currency1;

        // Record token balances before fee collection
        uint256 balance0Before = IERC20(Currency.unwrap(token0)).balanceOf(recipient);
        uint256 balance1Before = IERC20(Currency.unwrap(token1)).balanceOf(recipient);

        // Prepare actions: DECREASE_LIQUIDITY (with 0 liquidity) + TAKE_PAIR
        // This collects fees without removing any actual liquidity
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));

        bytes[] memory params = new bytes[](2);
        // DECREASE_LIQUIDITY params: (tokenId, liquidity128Delta, amount0Min, amount1Min, hookData)
        params[0] = abi.encode(nfpId, uint256(0), uint128(0), uint128(0), bytes(""));
        // TAKE_PAIR params: (currency0, currency1, recipient)
        params[1] = abi.encode(token0, token1, recipient);

        // Execute fee collection with short deadline
        uint256 deadline = block.timestamp + 60;
        POSITION_MANAGER_V4.modifyLiquidities(abi.encode(actions, params), deadline);

        // Calculate and emit the collected amounts
        uint256 balance0After = IERC20(Currency.unwrap(token0)).balanceOf(recipient);
        uint256 balance1After = IERC20(Currency.unwrap(token1)).balanceOf(recipient);

        uint256 collectedAmount0 = balance0After - balance0Before;
        uint256 collectedAmount1 = balance1After - balance1Before;

        emit FeesCollected(
            recipient, Currency.unwrap(token0), Currency.unwrap(token1), collectedAmount0, collectedAmount1
        );
    }
}
