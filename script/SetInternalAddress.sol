// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {SuperDCAGauge} from "../src/SuperDCAGauge.sol";
import {console2} from "forge-std/Test.sol";

contract SetInternalAddress is Script {
    uint256 deployerPrivateKey;
    address gaugeAddress;
    address userToSet;
    bool isInternal;

    function setUp() public {
        deployerPrivateKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        gaugeAddress = vm.envAddress("GAUGE_ADDRESS");
        if (gaugeAddress == address(0)) {
            revert("GAUGE_ADDRESS environment variable not set.");
        }
        userToSet = vm.envAddress("USER_TO_SET_INTERNAL");
        if (userToSet == address(0)) {
            revert("USER_TO_SET_INTERNAL environment variable not set.");
        }
        isInternal = vm.envBool("IS_INTERNAL");
    }

    function run() public {
        vm.startBroadcast(deployerPrivateKey);

        SuperDCAGauge gauge = SuperDCAGauge(payable(gaugeAddress));

        console2.log("Gauge Address:", address(gauge));
        console2.log("User to set internal:", userToSet);
        console2.log("Set as internal:", isInternal);

        console2.log("Calling setInternalAddress()...");
        gauge.setInternalAddress(userToSet, isInternal);
        console2.log("Called setInternalAddress().");

        bool currentInternalStatus = gauge.isInternalAddress(userToSet);
        console2.log("Current internal status for user:", currentInternalStatus);

        if (currentInternalStatus == isInternal) {
            console2.log("Successfully set internal address status.");
        } else {
            console2.log("ERROR: Failed to set internal address status.");
        }

        vm.stopBroadcast();
    }
}
