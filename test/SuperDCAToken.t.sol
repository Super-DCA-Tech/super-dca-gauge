// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {SuperDCAToken} from "../src/SuperDCAToken.sol";

contract SuperDCATokenTest is Test {
    SuperDCAToken token;
    address owner;
    address alice;
    address bob;

    function setUp() public virtual {
        owner = makeAddr("Owner");
        alice = makeAddr("Alice");
        bob = makeAddr("Bob");

        vm.prank(owner);
        token = new SuperDCAToken();
    }
}

contract Constructor is SuperDCATokenTest {
    function test_SetsNameSymbolAndOwnerAndInitialSupply() public view {
        assertEq(token.name(), "Super DCA");
        assertEq(token.symbol(), "DCA");
        assertEq(token.owner(), owner);
        assertEq(token.totalSupply(), 10000 * 10 ** token.decimals());
        assertEq(token.balanceOf(owner), 10000 * 10 ** token.decimals());
    }
}

contract Mint is SuperDCATokenTest {
    function testFuzz_MintsWhenCalledByOwner(address _to, uint256 _amount) public {
        vm.assume(_to != address(0));
        _amount = bound(_amount, 1, type(uint256).max / 2);

        uint256 beforeBal = token.balanceOf(_to);
        uint256 beforeSupply = token.totalSupply();

        vm.prank(owner);
        token.mint(_to, _amount);

        assertEq(token.balanceOf(_to), beforeBal + _amount);
        assertEq(token.totalSupply(), beforeSupply + _amount);
    }

    function testFuzz_RevertIf_CallerIsNotOwner(address _caller, address _to, uint256 _amount) public {
        vm.assume(_caller != owner);
        vm.assume(_to != address(0));
        _amount = bound(_amount, 1, type(uint256).max / 2);

        vm.prank(_caller);
        vm.expectRevert();
        token.mint(_to, _amount);
    }
}
