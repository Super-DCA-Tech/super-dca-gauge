// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {Planner, Plan} from "lib/v4-periphery/test/shared/Planner.sol";
import {PositionConfig} from "lib/v4-periphery/test/shared/PositionConfig.sol";

/**
 * @title PositionMintHelper
 * @notice Helper library for minting Uniswap v4 positions in tests
 * @dev Provides utilities for minting full-range and custom-range positions
 */
library PositionMintHelper {
    using TickMath for int24;

    uint128 constant MAX_SLIPPAGE = type(uint128).max;

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
     * @notice Mint a full-range position using the PositionManager
     * @param pm The PositionManager contract
     * @param key The pool key for the position
     * @param liquidity The amount of liquidity to add
     * @param recipient The recipient of the minted NFT
     * @return nftId The ID of the minted NFT
     */
    function mintFullRange(
        IPositionManager pm,
        PoolKey memory key,
        uint256 liquidity,
        address recipient
    ) internal returns (uint256 nftId) {
        (int24 lower, int24 upper) = fullRangeTicks(key.tickSpacing);
        return mintCustomRange(pm, key, lower, upper, liquidity, recipient);
    }

    /**
     * @notice Mint a custom-range position using the PositionManager
     * @param pm The PositionManager contract
     * @param key The pool key for the position
     * @param lower The lower tick of the position
     * @param upper The upper tick of the position
     * @param liquidity The amount of liquidity to add
     * @param recipient The recipient of the minted NFT
     * @return nftId The ID of the minted NFT
     */
    function mintCustomRange(
        IPositionManager pm,
        PoolKey memory key,
        int24 lower,
        int24 upper,
        uint256 liquidity,
        address recipient
    ) internal returns (uint256 nftId) {
        // Store the next token ID before minting
        nftId = pm.nextTokenId();

        // Create the position config
        PositionConfig memory config = PositionConfig({
            poolKey: key,
            tickLower: lower,
            tickUpper: upper
        });

        // Create the mint plan using Planner
        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                config.poolKey,
                config.tickLower,
                config.tickUpper,
                liquidity,
                MAX_SLIPPAGE, // amount0Max
                MAX_SLIPPAGE, // amount1Max
                recipient,
                bytes("") // hookData
            )
        );

        // Finalize the plan and execute the mint
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(config.poolKey);
        pm.modifyLiquidities(calls, block.timestamp + 1);
    }
}