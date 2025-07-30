// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {MyToken} from "src/MyToken.sol";

contract MyTokenTest is Test {
  MyToken public instance;

  function setUp() public {
    address defaultAdmin = vm.addr(1);
    address upgrader = vm.addr(2);
    address proxy = Upgrades.deployUUPSProxy(
      "MyToken.sol",
      abi.encodeCall(MyToken.initialize, (defaultAdmin, upgrader))
    );
    instance = MyToken(proxy);
  }

  function testName() public view {
    assertEq(instance.name(), "MyToken");
  }
}
