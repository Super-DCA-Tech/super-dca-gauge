// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {MockERC20Token} from "../mocks/MockERC20Token.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Planner, Plan} from "lib/v4-periphery/test/shared/Planner.sol";
import {PositionConfig} from "lib/v4-periphery/test/shared/PositionConfig.sol";

/**
 * @title IntegrationHelpers
 * @notice Helper functions for integration testing with real Uniswap v4 contracts
 * @dev Provides utilities to mint positions, perform swaps, and generate real fees
 * 
 * This contract replaces the previous mock-based testing approach with real Uniswap v4
 * contract interactions. It enables:
 * 
 * 1. **Real Position Creation**: Uses the actual PositionManager to mint NFT positions
 *    with real liquidity, replacing vm.mockCall position mocking
 * 
 * 2. **Genuine Fee Generation**: Performs actual swaps through SwapRouter to accumulate
 *    real fees in positions, replacing FeesCollectionMock simulations
 * 
 * 3. **Authentic Validation**: Tests can validate against real position data, liquidity
 *    amounts, and fee balances from actual Uniswap v4 state
 * 
 * **Integration Flow for Fee Collection Tests:**
 * - setupPoolWithLiquidity() → mintFullRangePosition() → generateSignificantFees() → collectFees()
 * 
 * **Integration Flow for Position Listing Tests:**
 * - mintFullRangePosition() / mintNarrowRangePosition() → hook.list() → validate real position data
 * 
 * This approach provides higher confidence that the hook works correctly with actual
 * Uniswap v4 deployments and catches integration issues that mocks would miss.
 */
contract IntegrationHelpers is Test {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /**
     * @notice Mint a real position using the PositionManager
     * @param posManager The PositionManager contract
     * @param poolKey The pool key for the position
     * @param tickLower The lower tick for the position
     * @param tickUpper The upper tick for the position  
     * @param liquidity The liquidity amount to mint
     * @param amount0Max Maximum amount of token0 to spend
     * @param amount1Max Maximum amount of token1 to spend
     * @param recipient The recipient of the minted NFT
     * @return tokenId The minted NFT token ID
     */
    function mintPosition(
        IPositionManager posManager,
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        address recipient
    ) public returns (uint256 tokenId) {
        // Approve tokens for the position manager
        MockERC20Token(Currency.unwrap(poolKey.currency0)).approve(address(posManager), amount0Max);
        MockERC20Token(Currency.unwrap(poolKey.currency1)).approve(address(posManager), amount1Max);

        // Get the next token ID
        tokenId = posManager.nextTokenId();

        // Create position config
        PositionConfig memory config = PositionConfig({
            poolKey: poolKey,
            tickLower: tickLower,
            tickUpper: tickUpper
        });

        // Create the plan using Planner
        Plan memory planner = Planner.init();
        planner = planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                poolKey,
                tickLower,
                tickUpper,
                liquidity,
                uint128(amount0Max),
                uint128(amount1Max),
                recipient,
                "" // hookData
            )
        );

        // Finalize and execute
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(poolKey);
        posManager.modifyLiquidities(calls, block.timestamp + 60);
    }

    /**
     * @notice Mint a full-range position for testing
     * @param posManager The PositionManager contract
     * @param poolKey The pool key for the position
     * @param liquidity The liquidity amount to mint
     * @param recipient The recipient of the minted NFT
     * @return tokenId The minted NFT token ID
     */
    function mintFullRangePosition(
        IPositionManager posManager,
        PoolKey memory poolKey,
        uint256 liquidity,
        address recipient
    ) public returns (uint256 tokenId) {
        int24 tickSpacing = poolKey.tickSpacing;
        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);
        
        // Calculate approximate amounts needed for the liquidity
        (uint160 sqrtPriceX96,,,) = IPoolManager(posManager.poolManager()).getSlot0(poolKey.toId());
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(minTick),
            TickMath.getSqrtPriceAtTick(maxTick),
            uint128(liquidity)
        );
        
        return mintPosition(
            posManager,
            poolKey,
            minTick,
            maxTick,
            liquidity,
            amount0 * 110 / 100, // 10% slippage buffer
            amount1 * 110 / 100, // 10% slippage buffer
            recipient
        );
    }

    /**
     * @notice Mint a narrow-range position for testing edge cases
     * @param posManager The PositionManager contract
     * @param poolKey The pool key for the position
     * @param liquidity The liquidity amount to mint
     * @param recipient The recipient of the minted NFT
     * @return tokenId The minted NFT token ID
     */
    function mintNarrowRangePosition(
        IPositionManager posManager,
        PoolKey memory poolKey,
        uint256 liquidity,
        address recipient
    ) public returns (uint256 tokenId) {
        int24 tickSpacing = poolKey.tickSpacing;
        // Create a narrow range around current price
        int24 tickLower = -tickSpacing;
        int24 tickUpper = tickSpacing;
        
        // Calculate approximate amounts needed for the liquidity
        (uint160 sqrtPriceX96,,,) = IPoolManager(posManager.poolManager()).getSlot0(poolKey.toId());
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            uint128(liquidity)
        );
        
        return mintPosition(
            posManager,
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            amount0 * 110 / 100, // 10% slippage buffer
            amount1 * 110 / 100, // 10% slippage buffer
            recipient
        );
    }

    /**
     * @notice Perform swaps to generate fees in a pool
     * @param swapRouter The swap router contract
     * @param poolKey The pool key to swap in
     * @param amountIn The amount to swap in
     * @param zeroForOne Direction of the swap
     */
    function generateFeesWithSwaps(
        PoolSwapTest swapRouter,
        PoolKey memory poolKey,
        uint256 amountIn,
        bool zeroForOne
    ) public {
        // Approve tokens for swap
        Currency inputCurrency = zeroForOne ? poolKey.currency0 : poolKey.currency1;
        MockERC20Token(Currency.unwrap(inputCurrency)).approve(address(swapRouter), amountIn);

        // Perform swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn), // Exact input
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(
            poolKey,
            params,
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /**
     * @notice Perform multiple swaps in both directions to generate significant fees
     * @param swapRouter The swap router contract
     * @param poolKey The pool key to swap in
     * @param baseAmount The base amount for each swap
     * @param numSwaps Number of swaps to perform in each direction
     */
    function generateSignificantFees(
        PoolSwapTest swapRouter,
        PoolKey memory poolKey,
        uint256 baseAmount,
        uint256 numSwaps
    ) public {
        for (uint256 i = 0; i < numSwaps; i++) {
            // Swap token0 for token1
            generateFeesWithSwaps(swapRouter, poolKey, baseAmount, true);
            
            // Swap token1 for token0
            generateFeesWithSwaps(swapRouter, poolKey, baseAmount / 2, false);
        }
    }

    /**
     * @notice Set up a pool with liquidity for fee generation using token amounts
     * @param manager The pool manager
     * @param posManager The position manager
     * @param poolKey The pool key
     * @param amount0 Amount of token0 to add
     * @param amount1 Amount of token1 to add
     * @return tokenId The NFT token ID of the position
     */
    function setupPoolWithLiquidity(
        IPoolManager manager,
        IPositionManager posManager,
        PoolKey memory poolKey,
        uint256 amount0,
        uint256 amount1
    ) public returns (uint256 tokenId) {
        // Mint tokens if needed
        MockERC20Token token0 = MockERC20Token(Currency.unwrap(poolKey.currency0));
        MockERC20Token token1 = MockERC20Token(Currency.unwrap(poolKey.currency1));
        
        if (token0.balanceOf(address(this)) < amount0) {
            token0.mint(address(this), amount0 * 2);
        }
        if (token1.balanceOf(address(this)) < amount1) {
            token1.mint(address(this), amount1 * 2);
        }

        // Calculate liquidity for these amounts
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolKey.toId());
        int24 tickSpacing = poolKey.tickSpacing;
        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);
        
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(minTick),
            TickMath.getSqrtPriceAtTick(maxTick),
            amount0,
            amount1
        );

        // Mint full range position
        return mintFullRangePosition(
            posManager,
            poolKey,
            liquidity,
            address(this)
        );
    }

    /**
     * @notice Get the current fee amounts that can be collected from a position
     * @param posManager The position manager
     * @param tokenId The NFT token ID
     * @return amount0 The amount of token0 fees
     * @return amount1 The amount of token1 fees
     */
    function getPositionFees(
        IPositionManager posManager,
        uint256 tokenId
    ) public view returns (uint256 amount0, uint256 amount1) {
        // Note: This would need to be implemented based on the actual PositionManager interface
        // For now, we'll approximate based on the position's share of pool fees
        // In a real implementation, this would call the actual fee collection preview function
        
        // This is a placeholder - the actual implementation would depend on 
        // the specific PositionManager interface for fee preview
        return (0, 0);
    }
}