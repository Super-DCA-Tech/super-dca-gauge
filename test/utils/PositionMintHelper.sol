// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

/**
 * @title PositionMintHelper
 * @notice Helper library for adding liquidity to Uniswap v4 pools in tests
 * @dev Provides utilities for adding full-range and custom-range liquidity using modifyLiquidityRouter
 */
library PositionMintHelper {
    using TickMath for int24;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /**
     * @notice Calculate full-range tick boundaries for a given tick spacing
     * @param spacing The tick spacing of the pool
     * @return lower The minimum usable tick
     * @return upper The maximum usable tick
     */
    function fullRangeTicks(int24 spacing) internal pure returns (int24 lower, int24 upper) {
        lower = TickMath.minUsableTick(spacing);
        upper = TickMath.maxUsableTick(spacing);
    }

    /**
     * @notice Add full-range liquidity using modifyLiquidityRouter
     * @param modifyLiquidityRouter The modifyLiquidityRouter from Deployers
     * @param key The pool key for the position
     * @param liquidityDelta The amount of liquidity to add
     * @return positionId A unique identifier for this position (hash of key and ticks)
     */
    function mintFullRange(
        PoolModifyLiquidityTest modifyLiquidityRouter,
        PoolKey memory key,
        uint256 liquidityDelta,
        address /* recipient - not used in this pattern */
    ) internal returns (uint256 positionId) {
        (int24 lower, int24 upper) = fullRangeTicks(key.tickSpacing);
        return mintCustomRange(modifyLiquidityRouter, key, lower, upper, liquidityDelta);
    }

    /**
     * @notice Add custom-range liquidity using modifyLiquidityRouter  
     * @param modifyLiquidityRouter The modifyLiquidityRouter from Deployers
     * @param key The pool key for the position
     * @param lower The lower tick of the position
     * @param upper The upper tick of the position
     * @param liquidityDelta The amount of liquidity to add
     * @return positionId A unique identifier for this position (hash of key and ticks)
     */
    function mintCustomRange(
        PoolModifyLiquidityTest modifyLiquidityRouter,
        PoolKey memory key,
        int24 lower,
        int24 upper,
        uint256 liquidityDelta
    ) internal returns (uint256 positionId) {
        // Create liquidity params
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: lower,
            tickUpper: upper,
            liquidityDelta: int128(int256(liquidityDelta)),
            salt: bytes32(0)
        });

        // Add liquidity using modifyLiquidityRouter
        modifyLiquidityRouter.modifyLiquidity(key, params, bytes(""));

        // Generate a unique position ID based on key and tick range
        positionId = uint256(keccak256(abi.encode(key, lower, upper, liquidityDelta)));
    }

    /**
     * @notice Get position liquidity from the pool manager
     * @param poolManager The pool manager
     * @param key The pool key
     * @param lower The lower tick
     * @param upper The upper tick
     * @return liquidity The liquidity in the position
     */
    function getPositionLiquidity(
        IPoolManager poolManager,
        PoolKey memory key,
        int24 lower,
        int24 upper
    ) internal view returns (uint128 liquidity) {
        return poolManager.getPosition(key.toId(), address(this), lower, upper, bytes32(0)).liquidity;
    }
}