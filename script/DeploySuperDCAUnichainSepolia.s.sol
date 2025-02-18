// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {DeploySuperDCATokenBase} from "./DeploySuperDCATokenBase.sol";
import {SuperDCAToken} from "../src/SuperDCAToken.sol";
import {SuperDCAGauge} from "../src/SuperDCAGauge.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract DeploySuperDCAUnichainSepolia is DeploySuperDCATokenBase {
    // Token constants
    address constant ADMIN = 0xe6D029C4c6e9c60aD0E49d92C850CD8d3E6C394a;
    address constant PAUSER = 0xe6D029C4c6e9c60aD0E49d92C850CD8d3E6C394a;
    address constant MINTER = 0xe6D029C4c6e9c60aD0E49d92C850CD8d3E6C394a;
    address constant UPGRADER = 0xe6D029C4c6e9c60aD0E49d92C850CD8d3E6C394a;

    // Hook constants
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant DEVELOPER = 0xe6D029C4c6e9c60aD0E49d92C850CD8d3E6C394a;
    uint256 constant MINT_RATE = 3858024691358024; // 10K per month as wei per second

    // Pool constants
    address constant ETH = address(0); // Native ETH uses address(0)
    address constant USDC = 0x31d0220469e10c4E71834a79b1f276d740d3768F; // Sepolia USDC
    uint24 constant POOL_FEE = 500; // 0.05%
    int24 constant TICK_SPACING = 60;

    // Initial prices
    // For ETH/DCA: 1 DCA = 0.0001 ETH (both 18 decimals, no adjustment needed)
    uint160 constant INITIAL_SQRT_PRICE_ETH = 7922816251426433759354395034; // sqrt(0.0001) * 2^96

    // For USDC/DCA: 1 DCA = 1 USDC
    // Need to account for decimal difference: USDC (6) vs DCA (18)
    // 2^96 * 10^-12 = 79228162514264337593543950336 * 10^-12 = 79228162514264
    uint160 constant INITIAL_SQRT_PRICE_USDC = 79228162514264; // 1:1 price accounting for decimal difference

    function run() public override returns (SuperDCAToken, SuperDCAGauge) {
        return super.run();
    }

    function getTokenConfiguration() public pure override returns (TokenConfiguration memory) {
        return TokenConfiguration({
            defaultAdmin: ADMIN,
            pauser: PAUSER,
            minter: MINTER,
            upgrader: UPGRADER
        });
    }

    function getHookConfiguration() public pure override returns (HookConfiguration memory) {
        return HookConfiguration({
            poolManager: POOL_MANAGER,
            developerAddress: DEVELOPER,
            mintRate: MINT_RATE
        });
    }

    function getPoolConfiguration() public pure override returns (PoolConfiguration memory) {
        return PoolConfiguration({
            // ETH pool config
            token0: ETH,
            fee0: POOL_FEE,
            tickSpacing0: TICK_SPACING,
            initialSqrtPriceX96_0: INITIAL_SQRT_PRICE_ETH,
            // USDC pool config
            token1: USDC,
            fee1: POOL_FEE,
            tickSpacing1: TICK_SPACING,
            initialSqrtPriceX96_1: INITIAL_SQRT_PRICE_USDC
        });
    }
}
