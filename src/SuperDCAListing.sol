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
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "lib/v4-core/test/utils/LiquidityAmounts.sol";

import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {ISuperDCAListing} from "./interfaces/ISuperDCAListing.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";

/// @title SuperDCAListing
/// @notice Manages listing of tokens for Super DCA by taking custody of full-range Uniswap v4 NFP positions
///         that pair `SUPER_DCA_TOKEN` with the listed token and meet minimum liquidity requirements.
/// @dev Enforces that the position's hook matches the configured gauge hook and that the position is full-range.
///      Uses Ownable2Step; the owner can configure the hook, minimum liquidity, and collect fees.
contract SuperDCAListing is ISuperDCAListing, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    // External dependencies
    /// @notice The Uniswap v4 `IPoolManager` used for pool state queries.
    IPoolManager public immutable POOL_MANAGER;
    /// @notice The Uniswap v4 `IPositionManager` used to query and manage NFP positions.
    IPositionManager public immutable POSITION_MANAGER_V4;

    // Configuration
    /// @notice The address of the Super DCA ERC20 token that must be one side of any listed pool.
    address public immutable SUPER_DCA_TOKEN;
    /// @notice The expected Uniswap v4 hook (gauge) address; must match the hook embedded in a listed pool's `PoolKey`.
    IHooks public expectedHooks; // Gauge hook address that must match key.hooks

    // Listing state
    /// @notice The minimum amount of Super DCA token liquidity required in the full-range position to list the token.
    uint256 public minLiquidity = 1000 * 10 ** 18; // Minimum DCA liquidity required
    /// @notice Tracks whether a token has been listed.
    mapping(address token => bool listed) public override isTokenListed;
    /// @notice Maps a listed NFP tokenId to the corresponding listed token address.
    mapping(uint256 nfpId => address token) public override tokenOfNfp;

    // Events
    /// @notice Emitted when a token is successfully listed by transferring custody of the NFP to this contract.
    event TokenListed(address indexed token, uint256 indexed nftId, PoolKey key);
    /// @notice Emitted when the minimum required liquidity is updated.
    event MinimumLiquidityUpdated(uint256 oldMin, uint256 newMin);
    /// @notice Emitted when the expected hook (gauge) address is updated.
    event HookAddressSet(address indexed oldHook, address indexed newHook);
    /// @notice Emitted after fees are collected for a listed position.
    event FeesCollected(
        address indexed recipient, address indexed token0, address indexed token1, uint256 amount0, uint256 amount1
    );

    // Errors
    /// @notice Thrown when `nftId` is zero or when a required Uniswap token address is not set.
    error UniswapTokenNotSet();
    /// @notice Thrown when the provided `PoolKey.hooks` does not match the configured `expectedHooks`.
    error IncorrectHookAddress();
    /// @notice Thrown when the detected Super DCA token liquidity does not meet `minLiquidity`.
    error LowLiquidity();
    /// @notice Thrown when the NFP does not represent a full-range position for the pool's tick spacing.
    error NotFullRangePosition();
    /// @notice Thrown when attempting to list a token that is already listed.
    error TokenAlreadyListed();
    /// @notice Thrown when a zero address is provided where a non-zero address is required.
    error ZeroAddress();
    /// @notice Thrown when an invalid (e.g. zero) address is supplied for operations like fee collection recipient.
    error InvalidAddress();
    /// @notice Thrown when the provided `PoolKey` does not match the actual key derived from the NFP.
    error MismatchedPoolKey();

    /// @notice Initializes the SuperDCAListing contract.
    /// @param _superDCAToken The address of the Super DCA ERC20 token.
    /// @param _poolManager The Uniswap v4 `IPoolManager` address.
    /// @param _positionManagerV4 The Uniswap v4 `IPositionManager` address.
    /// @param _admin The address that will be granted `DEFAULT_ADMIN_ROLE`.
    /// @param _expectedHooks The expected hook (gauge) address embedded in valid `PoolKey`s.
    constructor(
        address _superDCAToken,
        IPoolManager _poolManager,
        IPositionManager _positionManagerV4,
        address _admin,
        IHooks _expectedHooks
    ) Ownable(_admin) {
        if (_superDCAToken == address(0)) revert ZeroAddress();
        SUPER_DCA_TOKEN = _superDCAToken;
        POOL_MANAGER = _poolManager;
        POSITION_MANAGER_V4 = _positionManagerV4;
        expectedHooks = _expectedHooks;
    }

    /// @notice Sets the expected Uniswap v4 hook (gauge) address that must match any listed position's `PoolKey.hooks`.
    /// @dev Callable only by the owner.
    /// @param _newHook The new hook address to enforce.
    function setHookAddress(IHooks _newHook) external {
        _checkOwner();
        emit HookAddressSet(address(expectedHooks), address(_newHook));
        expectedHooks = _newHook;
    }

    /// @notice Updates the minimum Super DCA liquidity requirement for listing.
    /// @dev Callable only by the owner.
    /// @param _minLiquidity The new minimum liquidity threshold.
    function setMinimumLiquidity(uint256 _minLiquidity) external override {
        _checkOwner();
        uint256 old = minLiquidity;
        minLiquidity = _minLiquidity;
        emit MinimumLiquidityUpdated(old, _minLiquidity);
    }

    /// @notice Lists a token by validating and taking custody of a full-range Uniswap v4 position NFT.
    /// @dev Requirements:
    /// - `nftId != 0`
    /// - The provided `providedKey` must match the actual `PoolKey` for `nftId`.
    /// - `key.hooks` must equal `expectedHooks`.
    /// - The position must be full-range for `key.tickSpacing`.
    /// - The detected Super DCA token liquidity must be at least `minLiquidity`.
    /// - The corresponding non-Super DCA token must not already be listed.
    /// On success, custody of the NFP is transferred to this contract and a `TokenListed` event is emitted.
    /// @param nftId The Uniswap v4 position tokenId to list.
    /// @param providedKey The `PoolKey` provided by the caller, which must match the position's actual key.
    function list(uint256 nftId, PoolKey calldata providedKey) external override {
        if (nftId == 0) revert UniswapTokenNotSet();

        // Derive the actual key from the position manager and ensure it matches caller input
        (PoolKey memory key,) = POSITION_MANAGER_V4.getPoolAndPositionInfo(nftId);
        if (
            Currency.unwrap(key.currency0) != Currency.unwrap(providedKey.currency0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(providedKey.currency1) || key.fee != providedKey.fee
                || key.tickSpacing != providedKey.tickSpacing || address(key.hooks) != address(providedKey.hooks)
        ) {
            revert MismatchedPoolKey();
        }

        // hooks address must match configured hook (the gauge)
        // also enforces dynamic fee and the DCA token being in the pool
        if (address(key.hooks) != address(expectedHooks)) revert IncorrectHookAddress();

        // full-range enforcement via position info
        {
            PositionInfo _pi = POSITION_MANAGER_V4.positionInfo(nftId);
            int24 _tickLower = _pi.tickLower();
            int24 _tickUpper = _pi.tickUpper();
            if (
                _tickLower != TickMath.minUsableTick(key.tickSpacing)
                    || _tickUpper != TickMath.maxUsableTick(key.tickSpacing)
            ) {
                revert NotFullRangePosition();
            }

            // liquidity amounts
            uint128 _liquidity = POSITION_MANAGER_V4.getPositionLiquidity(nftId);
            (uint256 amount0, uint256 amount1) = _getAmountsForKey(key, _tickLower, _tickUpper, _liquidity);

            address listedToken;
            uint256 dcaAmount;
            if (Currency.unwrap(key.currency0) == SUPER_DCA_TOKEN) {
                listedToken = Currency.unwrap(key.currency1);
                dcaAmount = amount0;
            } else {
                listedToken = Currency.unwrap(key.currency0);
                dcaAmount = amount1;
            }

            if (dcaAmount < minLiquidity) revert LowLiquidity();
            if (isTokenListed[listedToken]) revert TokenAlreadyListed();

            // mark listed and map NFP
            isTokenListed[listedToken] = true;
            tokenOfNfp[nftId] = listedToken;
        }

        // take custody of the NFP
        IERC721(address(POSITION_MANAGER_V4)).transferFrom(msg.sender, address(this), nftId);
        emit TokenListed(tokenOfNfp[nftId], nftId, key);
    }

    /// @notice Computes token amounts represented by a given full-range liquidity position.
    /// @dev Uses the current pool price from `POOL_MANAGER.getSlot0` and standard Uniswap v4 helpers.
    /// @param key The pool key.
    /// @param tickLower The lower tick of the position (expected min usable tick).
    /// @param tickUpper The upper tick of the position (expected max usable tick).
    /// @param liquidity The position liquidity.
    /// @return amount0 The calculated amount of token0 represented by the position.
    /// @return amount1 The calculated amount of token1 represented by the position.
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

    /// @notice Collects fees for a listed position and sends them to `recipient`.
    /// @dev Callable only by the owner.
    /// Reverts if `nfpId` is zero or `recipient` is the zero address.
    /// Emits `FeesCollected` with the deltas of the recipient's token balances.
    /// @param nfpId The Uniswap v4 position tokenId whose fees to collect.
    /// @param recipient The address to receive the collected fees.
    function collectFees(uint256 nfpId, address recipient) external override {
        _checkOwner();
        if (nfpId == 0) revert UniswapTokenNotSet();
        if (recipient == address(0)) revert InvalidAddress();

        (PoolKey memory key,) = POSITION_MANAGER_V4.getPoolAndPositionInfo(nfpId);
        Currency token0 = key.currency0;
        Currency token1 = key.currency1;

        uint256 balance0Before = IERC20(Currency.unwrap(token0)).balanceOf(recipient);
        uint256 balance1Before = IERC20(Currency.unwrap(token1)).balanceOf(recipient);

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(nfpId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(token0, token1, recipient);

        uint256 deadline = block.timestamp + 60;
        POSITION_MANAGER_V4.modifyLiquidities(abi.encode(actions, params), deadline);

        uint256 balance0After = IERC20(Currency.unwrap(token0)).balanceOf(recipient);
        uint256 balance1After = IERC20(Currency.unwrap(token1)).balanceOf(recipient);

        uint256 collectedAmount0 = balance0After - balance0Before;
        uint256 collectedAmount1 = balance1After - balance1Before;

        emit FeesCollected(
            recipient, Currency.unwrap(token0), Currency.unwrap(token1), collectedAmount0, collectedAmount1
        );
    }
}
