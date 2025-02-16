// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {SuperDCAToken} from "src/SuperDCAToken.sol";

contract SuperDCATest is Test {
    SuperDCAToken public instance;

    function setUp() public {
        address defaultAdmin = vm.addr(1);
        address pauser = vm.addr(2);
        address minter = vm.addr(3);
        address upgrader = vm.addr(4);
        address proxy = Upgrades.deployUUPSProxy(
            "SuperDCAToken.sol", abi.encodeCall(SuperDCAToken.initialize, (defaultAdmin, pauser, minter, upgrader))
        );
        instance = SuperDCAToken(proxy);
    }

    function testName() public view {
        assertEq(instance.name(), "Super DCA");
    }
}
