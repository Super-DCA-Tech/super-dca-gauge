// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {DeployGaugeBase} from "./DeployGaugeBase.sol";
import {SuperDCAGauge} from "../src/SuperDCAGauge.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract DeployGaugeBaseSepolia is DeployGaugeBase {
    // Hook constants
    address public constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address public constant DEVELOPER = 0xe6D029C4c6e9c60aD0E49d92C850CD8d3E6C394a;
    uint256 public constant MINT_RATE = 3858024691358024; // 10K per month as wei per second

    // Pool constants, use two stablecoins (1:1) for keeping the math easier on testnet
    address public constant FUSDC = 0x6B0dacea6a72E759243c99Eaed840DEe9564C194; // Fake USDC from SF
    address public constant FDAI = 0x6b008BAc0e5846cB5d9Ca02ca0e801fCbF88B6f9; // Fake DAI from SF
    
    // Initial prices (1:1 ratio since both are stablecoins)
    uint160 public constant INITIAL_SQRT_PRICE_FUSDC = 79228162514264337593543950336;
    uint160 public constant INITIAL_SQRT_PRICE_FDAI = 79228162514264337593543950336;

    function run() public override returns (SuperDCAGauge) {
        return super.run();
    }

    function getHookConfiguration() public pure override returns (HookConfiguration memory) {
        return HookConfiguration({poolManager: POOL_MANAGER, developerAddress: DEVELOPER, mintRate: MINT_RATE});
    }

    function getPoolConfiguration() public pure override returns (PoolConfiguration memory) {
        return PoolConfiguration({
            token0: FUSDC, 
            token1: FDAI,
            initialSqrtPrice0: INITIAL_SQRT_PRICE_FUSDC,
            initialSqrtPrice1: INITIAL_SQRT_PRICE_FDAI
        });
    }
}
