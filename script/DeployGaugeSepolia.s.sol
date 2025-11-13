// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {DeployGaugeBase} from "./DeployGaugeBase.sol";
import {SuperDCAGauge} from "../src/SuperDCAGauge.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract DeployGaugeSepolia is DeployGaugeBase {
    // Hook constants
    address public constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address public constant POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address public constant UNIVERSAL_ROUTER = 0x492E6456D9528771018DeB9E87ef7750EF184104;
    address public constant DEVELOPER = 0x6a89abA79880D810C286070d999fdCbaC8d7CdaF;
    uint256 public constant MINT_RATE = 3858024691358024; // 10K per month as wei per second

    // Pool constants
    address public constant ETH = address(0); // Native ETH uses address(0)
    address public constant USDC = 0xe72f289584eDA2bE69Cfe487f4638F09bAc920Db; // fUSDC
    address public constant WBTC = 0x4E89088Cd14064f38E5B2F309cFaB9C864F9a8e6; // fDAI

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
