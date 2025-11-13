// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {DeployGaugeBase} from "./DeployGaugeBase.sol";
import {SuperDCAGauge} from "../src/SuperDCAGauge.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract DeployGaugeBaseOptimism is DeployGaugeBase {
    // Hook constants
    address public constant POOL_MANAGER = 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3;
    address public constant POSITION_MANAGER = 0x3C3Ea4B57a46241e54610e5f022E5c45859A1017;
    address public constant UNIVERSAL_ROUTER = 0x851116D9223fabED8E56C0E6b8Ad0c31d98B3507;
    uint256 public constant MINT_RATE = 3858024691358024; // 10K per month as wei per second

    // Pool constants
    address public constant ETH = address(0); // Native ETH uses address(0)
    address public constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address public constant WBTC = 0x68f180fcCe6836688e9084f035309E29Bf0A2095; 

    function run() public override returns (DeployedContracts memory) {
        return super.run();
    }

    function getHookConfiguration() public pure override returns (HookConfiguration memory) {
        return HookConfiguration({poolManager: POOL_MANAGER, mintRate: MINT_RATE, positionManager: POSITION_MANAGER, universalRouter: UNIVERSAL_ROUTER});
    }

    function getPoolConfiguration() public pure override returns (PoolConfiguration memory) {
        return PoolConfiguration({eth: ETH, usdc: USDC, wbtc: WBTC});
    }
}
