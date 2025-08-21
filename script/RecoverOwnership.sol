// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {SuperDCAGauge} from "../src/SuperDCAGauge.sol";
import {ISuperchainERC20} from "../src/interfaces/ISuperchainERC20.sol";
import {console2} from "forge-std/Test.sol";

contract RecoverOwnership is Script {
    address public constant DCA_TOKEN = 0xb1599CDE32181f48f89683d3C5Db5C5D2C7C93cc;
    uint256 deployerPrivateKey;
    address gaugeAddress;

    function setUp() public {
        deployerPrivateKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        gaugeAddress = vm.envAddress("GAUGE_ADDRESS");
        if (gaugeAddress == address(0)) {
            revert("GAUGE_ADDRESS environment variable not set.");
        }
    }

    function run() public {
        vm.startBroadcast(deployerPrivateKey);

        SuperDCAGauge gauge = SuperDCAGauge(payable(gaugeAddress));
        ISuperchainERC20 dcaToken = ISuperchainERC20(DCA_TOKEN);
        address initialOwner = dcaToken.owner();
        address expectedNewOwner = vm.addr(deployerPrivateKey);

        console2.log("Gauge Address:", address(gauge));
        console2.log("DCA Token Address:", address(dcaToken));
        console2.log("Current DCA Token Owner:", initialOwner);
        console2.log("Expected New Owner (Deployer):", expectedNewOwner);

        if (initialOwner != address(gauge)) {
            console2.log("Gauge does not own the token. Skipping recovery.");
        } else {
            console2.log("Calling returnSuperDCATokenOwnership()...");
            gauge.returnSuperDCATokenOwnership();
            console2.log("Called returnSuperDCATokenOwnership().");

            address finalOwner = dcaToken.owner();
            console2.log("Final DCA Token Owner:", finalOwner);

            if (finalOwner == expectedNewOwner) {
                console2.log("Ownership successfully recovered by deployer.");
            } else {
                console2.log("ERROR: Ownership recovery failed. Final owner is not the deployer.");
            }
        }

        vm.stopBroadcast();
    }
}
