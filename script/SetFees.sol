// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {SuperDCAGauge} from "../src/SuperDCAGauge.sol";
import {console2} from "forge-std/Test.sol";

contract SetFees is Script {
    uint256 deployerPrivateKey;
    address gaugeAddress;
    SuperDCAGauge.FeeType feeType;
    uint24 newFee;

    function setUp() public {
        deployerPrivateKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        gaugeAddress = vm.envAddress("GAUGE_ADDRESS");
        if (gaugeAddress == address(0)) {
            revert("GAUGE_ADDRESS environment variable not set.");
        }

        // Read fee type from environment (0=INTERNAL, 1=EXTERNAL, 2=KEEPER)
        uint256 feeTypeFromEnv = vm.envUint("FEE_TYPE");
        if (feeTypeFromEnv > 2) {
            revert("FEE_TYPE must be 0 (INTERNAL), 1 (EXTERNAL), or 2 (KEEPER).");
        }
        feeType = SuperDCAGauge.FeeType(feeTypeFromEnv);

        // forge-std does not have vm.envUint24, so we read as uint256 and cast
        uint256 feeFromEnv = vm.envUint("NEW_FEE");
        if (feeFromEnv > type(uint24).max) {
            revert("NEW_FEE exceeds maximum value for uint24.");
        }
        newFee = uint24(feeFromEnv);
    }

    function run() public {
        vm.startBroadcast(deployerPrivateKey);

        SuperDCAGauge gauge = SuperDCAGauge(payable(gaugeAddress));

        console2.log("Gauge Address:", address(gauge));

        string memory feeTypeName;
        if (feeType == SuperDCAGauge.FeeType.INTERNAL) {
            feeTypeName = "INTERNAL";
        } else if (feeType == SuperDCAGauge.FeeType.EXTERNAL) {
            feeTypeName = "EXTERNAL";
        } else {
            feeTypeName = "KEEPER";
        }
        console2.log("Setting fee type:", feeTypeName);
        console2.log("New fee value:", newFee);

        uint24 oldFee;
        if (feeType == SuperDCAGauge.FeeType.INTERNAL) {
            oldFee = gauge.internalFee();
        } else if (feeType == SuperDCAGauge.FeeType.EXTERNAL) {
            oldFee = gauge.externalFee();
        } else {
            oldFee = gauge.keeperFee();
        }
        console2.log("Old fee value:", oldFee);

        console2.log("Calling setFee()...");
        gauge.setFee(feeType, newFee);
        console2.log("Called setFee().");

        uint24 currentFee;
        if (feeType == SuperDCAGauge.FeeType.INTERNAL) {
            currentFee = gauge.internalFee();
        } else if (feeType == SuperDCAGauge.FeeType.EXTERNAL) {
            currentFee = gauge.externalFee();
        } else {
            currentFee = gauge.keeperFee();
        }
        console2.log("Current fee value:", currentFee);

        if (currentFee == newFee) {
            console2.log("Successfully set fee.");
        } else {
            console2.log("ERROR: Failed to set fee.");
        }

        vm.stopBroadcast();
    }
}
