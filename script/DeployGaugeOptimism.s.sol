// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {DeployGaugeBase} from "./DeployGaugeBase.sol";
import {SuperDCAGauge} from "../src/SuperDCAGauge.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract DeployGaugeBaseOptimism is DeployGaugeBase {
    // Hook constants
    address public constant POOL_MANAGER = 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3;
    address public constant DEVELOPER = 0xC07E21c78d6Ad0917cfCBDe8931325C392958892; // superdca.eth
    uint256 public constant MINT_RATE = 3858024691358024; // 10K per month as wei per second

    // Pool constants
    address public constant ETH = address(0); // Native ETH uses address(0)
    address public constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; // Sepolia USDC

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
