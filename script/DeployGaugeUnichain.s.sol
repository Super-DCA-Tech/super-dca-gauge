// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {DeployGaugeBase} from "./DeployGaugeBase.sol";
import {SuperDCAGauge} from "../src/SuperDCAGauge.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract DeployGaugeUnichain is DeployGaugeBase {
    // Hook constants
    address public constant POOL_MANAGER = 0x1F98400000000000000000000000000000000004;
    address public constant POSITION_MANAGER = 0x4529A01c7A0410167c5740C487A8DE60232617bf;
    address public constant UNIVERSAL_ROUTER = 0xEf740bf23aCaE26f6492B10de645D6B98dC8Eaf3;
    uint256 public constant MINT_RATE = 3858024691358024; // 10K per month as wei per second

    // Pool constants
    address public constant ETH = address(0);
    address public constant USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    function run() public override returns (DeployedContracts memory) {
        return super.run();
    }

    function getHookConfiguration() public pure override returns (HookConfiguration memory) {
        return HookConfiguration({
            poolManager: POOL_MANAGER,
            mintRate: MINT_RATE,
            positionManager: POSITION_MANAGER,
            universalRouter: UNIVERSAL_ROUTER
        });
    }

    function getPoolConfiguration() public pure override returns (PoolConfiguration memory) {
        return PoolConfiguration({eth: ETH, usdc: USDC, wbtc: WBTC});
    }
}
