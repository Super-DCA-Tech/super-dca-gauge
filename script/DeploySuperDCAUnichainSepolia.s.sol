// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {DeploySuperDCATokenBase} from "./DeploySuperDCATokenBase.sol";
import {SuperDCAToken} from "../src/SuperDCAToken.sol";
import {SuperDCAGauge} from "../src/SuperDCAGauge.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract DeploySuperDCAUnichainSepolia is DeploySuperDCATokenBase {
    // Token constants
    address public constant ADMIN = 0xe6D029C4c6e9c60aD0E49d92C850CD8d3E6C394a;
    address public constant PAUSER = 0xe6D029C4c6e9c60aD0E49d92C850CD8d3E6C394a;
    address public constant MINTER = 0xe6D029C4c6e9c60aD0E49d92C850CD8d3E6C394a;
    address public constant UPGRADER = 0xe6D029C4c6e9c60aD0E49d92C850CD8d3E6C394a;

    // Hook constants
    address public constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address public constant DEVELOPER = 0xe6D029C4c6e9c60aD0E49d92C850CD8d3E6C394a;
    uint256 public constant MINT_RATE = 3858024691358024; // 10K per month as wei per second

    // Pool constants
    address public constant ETH = address(0); // Native ETH uses address(0)
    address public constant USDC = 0x31d0220469e10c4E71834a79b1f276d740d3768F; // Sepolia USDC

    function run() public override returns (SuperDCAToken, SuperDCAGauge) {
        return super.run();
    }

    function getTokenConfiguration() public pure override returns (TokenConfiguration memory) {
        return TokenConfiguration({defaultAdmin: ADMIN, pauser: PAUSER, minter: MINTER, upgrader: UPGRADER});
    }

    function getHookConfiguration() public pure override returns (HookConfiguration memory) {
        return HookConfiguration({poolManager: POOL_MANAGER, developerAddress: DEVELOPER, mintRate: MINT_RATE});
    }

    function getPoolConfiguration() public pure override returns (PoolConfiguration memory) {
        return PoolConfiguration({token0: ETH, token1: USDC});
    }
}
