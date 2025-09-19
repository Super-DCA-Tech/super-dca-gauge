// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {SuperDCAGauge} from "../src/SuperDCAGauge.sol";
import {SuperDCAStaking} from "../src/SuperDCAStaking.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/Test.sol";

contract AddStake is Script {
    uint256 deployerPrivateKey;
    address gaugeAddress;
    address stakingAddress;
    address tokenToStake;
    uint256 amountToStake;
    address constant DCA_TOKEN = 0xb1599CDE32181f48f89683d3C5Db5C5D2C7C93cc;

    function setUp() public {
        deployerPrivateKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        gaugeAddress = vm.envAddress("GAUGE_ADDRESS");
        if (gaugeAddress == address(0)) {
            revert("GAUGE_ADDRESS environment variable not set.");
        }
        stakingAddress = vm.envAddress("STAKING_ADDRESS");
        if (stakingAddress == address(0)) {
            revert("STAKING_ADDRESS environment variable not set.");
        }
        tokenToStake = vm.envAddress("TOKEN_TO_STAKE");

        amountToStake = vm.envUint("AMOUNT_TO_STAKE");
        if (amountToStake == 0) {
            revert("AMOUNT_TO_STAKE environment variable not set or is zero.");
        }
    }

    function run() public {
        vm.startBroadcast(deployerPrivateKey);

        SuperDCAGauge gauge = SuperDCAGauge(payable(gaugeAddress));
        SuperDCAStaking staking = SuperDCAStaking(payable(stakingAddress));

        console2.log("Deployer Address:", vm.addr(deployerPrivateKey));
        console2.log("Gauge Address:", address(gauge));
        console2.log("Staking Address:", address(staking));
        console2.log("Token to stake:", tokenToStake);
        console2.log("Amount to stake:", amountToStake);

        // Approve the staking contract to spend our DCA tokens
        console2.log("Approving DCA token spend...");
        IERC20(DCA_TOKEN).approve(address(staking), amountToStake);
        console2.log("Approved DCA token spend.");

        // Add stake to the specified token via staking
        console2.log("Calling staking.stake()...");
        staking.stake(tokenToStake, amountToStake);
        console2.log("Called staking.stake().");

        vm.stopBroadcast();
    }
}
