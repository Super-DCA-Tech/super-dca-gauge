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
    address constant USDC = 0x31d0220469e10c4E71834a79b1f276d740d3768F; // Sepolia USDC
    uint24 constant POOL_FEE = 100; // 0.01%
    int24 constant TICK_SPACING = 60;
    // Initial price: 1 DCA = 1 USDC
    // Need to account for decimal difference: USDC (6) vs DCA (18)
    // 1 DCA = 1 USDC means we need to adjust by 12 decimal places (18 - 6)
    // 2^96 * 10^-12 = 79228162514264337593543950336 * 10^-12 = 79228162514264
    uint160 constant INITIAL_SQRT_PRICE = 79228162514264; // 1:1 price accounting for decimal difference

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
            otherToken: USDC, // Changed from wethAddress to otherToken
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            initialSqrtPriceX96: INITIAL_SQRT_PRICE
        });
    }
}
