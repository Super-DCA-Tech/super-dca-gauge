// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {DeployGaugeBase} from "./DeployGaugeBase.sol";
import {SuperDCAGauge} from "../src/SuperDCAGauge.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract DeployGaugeBaseNetwork is DeployGaugeBase {
    // Hook constants
    address public constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address public constant DEVELOPER = 0xC07E21c78d6Ad0917cfCBDe8931325C392958892; // superdca.eth
    uint256 public constant MINT_RATE = 3858024691358024; // 10K per month as wei per second

    // Pool constants
    address public constant ETH = address(0);
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() public override returns (SuperDCAGauge) {
        return super.run();
    }

    function getHookConfiguration() public pure override returns (HookConfiguration memory) {
        return HookConfiguration({poolManager: POOL_MANAGER, developerAddress: DEVELOPER, mintRate: MINT_RATE});
    }

    function getPoolConfiguration() public pure override returns (PoolConfiguration memory) {
        return PoolConfiguration({token0: ETH, token1: USDC});
    }
}
