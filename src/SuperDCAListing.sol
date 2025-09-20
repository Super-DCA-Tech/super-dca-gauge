// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
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

contract SuperDCAListing is ISuperDCAListing, AccessControl {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    // Roles
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    // External dependencies
    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManagerV4;

    // Configuration
    address public immutable superDCAToken;
    IHooks public expectedHooks; // Gauge hook address that must match key.hooks

    // Listing state
    uint256 public minLiquidity = 1000 * 10 ** 18; // Minimum DCA liquidity required
    mapping(address => bool) public override isTokenListed; // token => listed?
    mapping(uint256 => address) public override tokenOfNfp; // nfpId => listed token

    // Events
    event TokenListed(address indexed token, uint256 indexed nftId, PoolKey key);
    event MinimumLiquidityUpdated(uint256 oldMin, uint256 newMin);
    event HookAddressSet(address indexed oldHook, address indexed newHook);
    event FeesCollected(
        address indexed recipient, address indexed token0, address indexed token1, uint256 amount0, uint256 amount1
    );

    // Errors (mirroring legacy gauge for compatibility)
    error NotDynamicFee();
    error UniswapTokenNotSet();
    error IncorrectHookAddress();
    error LowLiquidity();
    error NotFullRangePosition();
    error TokenAlreadyListed();
    error PoolMustIncludeSuperDCAToken();
    error ZeroAddress();
    error InvalidAddress();

    constructor(
        address _superDCAToken,
        IPoolManager _poolManager,
        IPositionManager _positionManagerV4,
        address _admin,
        IHooks _expectedHooks
    ) {
        if (_superDCAToken == address(0) || _admin == address(0)) revert ZeroAddress();
        superDCAToken = _superDCAToken;
        poolManager = _poolManager;
        positionManagerV4 = _positionManagerV4;
        expectedHooks = _expectedHooks;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _admin);
    }

    function setHookAddress(IHooks _newHook) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit HookAddressSet(address(expectedHooks), address(_newHook));
        expectedHooks = _newHook;
    }

    function setMinimumLiquidity(uint256 _minLiquidity) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 old = minLiquidity;
        minLiquidity = _minLiquidity;
        emit MinimumLiquidityUpdated(old, _minLiquidity);
    }

    function list(uint256 nftId, PoolKey calldata key) external override {
        // hooks address must match configured hook (the gauge)
        if (address(key.hooks) != address(expectedHooks)) revert IncorrectHookAddress();

        if (nftId == 0) revert UniswapTokenNotSet();

        // dynamic fee enforcement
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();

        // pool must include the DCA token
        {
            address token0Addr = Currency.unwrap(key.currency0);
            address token1Addr = Currency.unwrap(key.currency1);
            if (token0Addr != superDCAToken && token1Addr != superDCAToken) {
                revert PoolMustIncludeSuperDCAToken();
            }
        }

        // full-range enforcement via position info
        {
            PositionInfo _pi = positionManagerV4.positionInfo(nftId);
            int24 _tickLower = _pi.tickLower();
            int24 _tickUpper = _pi.tickUpper();
            if (
                _tickLower != TickMath.minUsableTick(key.tickSpacing)
                    && _tickUpper != TickMath.maxUsableTick(key.tickSpacing)
            ) {
                revert NotFullRangePosition();
            }

            // liquidity amounts
            uint128 _liquidity = positionManagerV4.getPositionLiquidity(nftId);
            (uint256 amount0, uint256 amount1) = _getAmountsForKey(key, _tickLower, _tickUpper, _liquidity);

            address listedToken;
            uint256 dcaAmount;
            if (Currency.unwrap(key.currency0) == superDCAToken) {
                listedToken = Currency.unwrap(key.currency1);
                dcaAmount = amount0;
            } else if (Currency.unwrap(key.currency1) == superDCAToken) {
                listedToken = Currency.unwrap(key.currency0);
                dcaAmount = amount1;
            } else {
                revert PoolMustIncludeSuperDCAToken();
            }

            if (dcaAmount < minLiquidity) revert LowLiquidity();
            if (isTokenListed[listedToken]) revert TokenAlreadyListed();

            // mark listed and map NFP
            isTokenListed[listedToken] = true;
            tokenOfNfp[nftId] = listedToken;
        }

        // take custody of the NFP
        IERC721(address(positionManagerV4)).transferFrom(msg.sender, address(this), nftId);
        emit TokenListed(tokenOfNfp[nftId], nftId, key);
    }

    function _getAmountsForKey(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        return (LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, liquidity));
    }

    function collectFees(uint256 nfpId, address recipient) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (nfpId == 0) revert UniswapTokenNotSet();
        if (recipient == address(0)) revert InvalidAddress();

        (PoolKey memory key,) = positionManagerV4.getPoolAndPositionInfo(nfpId);
        Currency token0 = key.currency0;
        Currency token1 = key.currency1;

        uint256 balance0Before = IERC20(Currency.unwrap(token0)).balanceOf(recipient);
        uint256 balance1Before = IERC20(Currency.unwrap(token1)).balanceOf(recipient);

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(nfpId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(token0, token1, recipient);

        uint256 deadline = block.timestamp + 60;
        positionManagerV4.modifyLiquidities(abi.encode(actions, params), deadline);

        uint256 balance0After = IERC20(Currency.unwrap(token0)).balanceOf(recipient);
        uint256 balance1After = IERC20(Currency.unwrap(token1)).balanceOf(recipient);

        uint256 collectedAmount0 = balance0After - balance0Before;
        uint256 collectedAmount1 = balance1After - balance1Before;

        // TODO: Collected fees should be transferred to the protocol fees contract

        emit FeesCollected(
            recipient, Currency.unwrap(token0), Currency.unwrap(token1), collectedAmount0, collectedAmount1
        );
    }
}
