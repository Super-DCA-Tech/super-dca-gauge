// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {ISuperchainERC20} from "../src/interfaces/ISuperchainERC20.sol";
import {SuperDCAGauge} from "../src/SuperDCAGauge.sol";
import {console2} from "forge-std/Test.sol";

contract TransferOwnership is Script {
    address public constant DCA_TOKEN = 0x26AE4b2b875Ec1DC6e4FDc3e9C74E344c3b43A54;
    address public constant GAUGE_ADDRESS = 0x186B91A71955809464dE81fD8f39061C9961Fa80;
    uint256 deployerPrivateKey;
    address newOwner;

    function setUp() public {
        deployerPrivateKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        newOwner = vm.envAddress("NEW_OWNER");
        if (newOwner == address(0)) {
            revert("NEW_OWNER environment variable not set.");
        }
    }

    function run() public {
        vm.startBroadcast(deployerPrivateKey);

        ISuperchainERC20 dcaToken = ISuperchainERC20(DCA_TOKEN);
        SuperDCAGauge gauge = SuperDCAGauge(GAUGE_ADDRESS);
        address currentOwner = dcaToken.owner();
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("DCA Token Address:", address(dcaToken));
        console2.log("Gauge Address:", address(gauge));
        console2.log("Current Owner:", currentOwner);
        console2.log("Deployer Address:", deployer);

        // Verify we can transfer ownership to the gauge
        if (currentOwner != deployer) {
            console2.log("ERROR: Deployer is not the current owner. Cannot transfer ownership.");
            revert("Deployer is not the current owner.");
        }

        console2.log("Transferring ownership to new owner...");
        dcaToken.transferOwnership(GAUGE_ADDRESS);
        console2.log("Ownership transfer called.");

        // Verify we can recover ownership
        console2.log("Recovering ownership...");
        gauge.returnSuperDCATokenOwnership();
        console2.log("Ownership recovered.");

        // Transfer it back to the gauge
        console2.log("Transferring ownership back to the gauge...");
        dcaToken.transferOwnership(GAUGE_ADDRESS);
        console2.log("Ownership transferred back to the gauge...");

        vm.stopBroadcast();
    }
}

