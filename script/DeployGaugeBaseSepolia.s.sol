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
    address public constant ADMIN = address(0x2); // @note placeholders
    address public constant PAUSER = address(0x3); // @note placeholders

    // Pool constants
    address public constant ETH = address(0); // Native ETH uses address(0)
    address public constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e; // Sepolia USDC

    function run() public override returns (SuperDCAGauge) {
        return super.run();
    }

    function getHookConfiguration() public pure override returns (HookConfiguration memory) {
        return HookConfiguration({
            poolManager: POOL_MANAGER,
            developerAddress: DEVELOPER,
            adminAddress: ADMIN,
            pauserAddress: PAUSER,
            mintRate: MINT_RATE
        });
    }

    function getPoolConfiguration() public pure override returns (PoolConfiguration memory) {
        return PoolConfiguration({token0: ETH, token1: USDC});
    }
}
