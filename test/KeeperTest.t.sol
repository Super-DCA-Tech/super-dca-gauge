// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {SuperDCAGauge} from "../src/SuperDCAGauge.sol";
import {MockERC20Token} from "./mocks/MockERC20Token.sol";
import {SuperDCAGaugeTest} from "./SuperDCAGauge.t.sol";

contract KeeperTest is SuperDCAGaugeTest {
    address keeper1 = address(0x1111);
    address keeper2 = address(0x2222);
    
    event KeeperChanged(address indexed oldKeeper, address indexed newKeeper, uint256 deposit);

    function setUp() public override {
        super.setUp();
        
        // Mint tokens for keepers
        dcaToken.mint(keeper1, 1000e18);
        dcaToken.mint(keeper2, 1000e18);
    }

    function test_becomeKeeper_firstKeeper() public {
        uint256 depositAmount = 100e18;
        
        // Setup approval
        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), depositAmount);
        
        // Expect event
        vm.expectEmit(true, true, true, true);
        emit KeeperChanged(address(0), keeper1, depositAmount);
        
        // Become keeper
        hook.becomeKeeper(depositAmount);
        vm.stopPrank();
        
        // Verify state
        assertEq(hook.keeper(), keeper1, "Keeper should be set");
        assertEq(hook.keeperDeposit(), depositAmount, "Keeper deposit should be set");
        assertEq(dcaToken.balanceOf(keeper1), 1000e18 - depositAmount, "Keeper balance should decrease");
        assertEq(dcaToken.balanceOf(address(hook)), depositAmount, "Hook should hold deposit");
    }

    function test_becomeKeeper_replaceKeeper() public {
        uint256 firstDeposit = 100e18;
        uint256 secondDeposit = 200e18;
        
        // First keeper
        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), firstDeposit);
        hook.becomeKeeper(firstDeposit);
        vm.stopPrank();
        
        // Second keeper with higher deposit
        vm.startPrank(keeper2);
        dcaToken.approve(address(hook), secondDeposit);
        
        // Expect event
        vm.expectEmit(true, true, true, true);
        emit KeeperChanged(keeper1, keeper2, secondDeposit);
        
        hook.becomeKeeper(secondDeposit);
        vm.stopPrank();
        
        // Verify state
        assertEq(hook.keeper(), keeper2, "New keeper should be set");
        assertEq(hook.keeperDeposit(), secondDeposit, "New deposit should be set");
        
        // Verify refund
        assertEq(dcaToken.balanceOf(keeper1), 1000e18, "First keeper should be refunded");
        assertEq(dcaToken.balanceOf(keeper2), 1000e18 - secondDeposit, "Second keeper balance should decrease");
        assertEq(dcaToken.balanceOf(address(hook)), secondDeposit, "Hook should hold new deposit");
    }

    function test_becomeKeeper_revert_zeroAmount() public {
        vm.startPrank(keeper1);
        vm.expectRevert(SuperDCAGauge.ZeroAmount.selector);
        hook.becomeKeeper(0);
        vm.stopPrank();
    }

    function test_becomeKeeper_revert_insufficientDeposit() public {
        uint256 firstDeposit = 200e18;
        uint256 insufficientDeposit = 100e18;
        
        // First keeper
        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), firstDeposit);
        hook.becomeKeeper(firstDeposit);
        vm.stopPrank();
        
        // Try to become keeper with lower deposit
        vm.startPrank(keeper2);
        dcaToken.approve(address(hook), insufficientDeposit);
        vm.expectRevert(SuperDCAGauge.InsufficientBalance.selector);
        hook.becomeKeeper(insufficientDeposit);
        vm.stopPrank();
    }

    function test_becomeKeeper_sameDeposit() public {
        uint256 deposit = 100e18;
        
        // First keeper
        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), deposit);
        hook.becomeKeeper(deposit);
        vm.stopPrank();
        
        // Try to become keeper with same deposit
        vm.startPrank(keeper2);
        dcaToken.approve(address(hook), deposit);
        vm.expectRevert(SuperDCAGauge.InsufficientBalance.selector);
        hook.becomeKeeper(deposit);
        vm.stopPrank();
    }

    function test_keeperFeeStructure() public {
        // Setup keepers
        uint256 deposit = 100e18;
        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), deposit);
        hook.becomeKeeper(deposit);
        vm.stopPrank();
        
        // Test fee structure through the contract's public interface
        // We can verify the keeper state is correct and would affect fees
        assertEq(hook.keeper(), keeper1, "Keeper should be set for fee application");
        
        // Verify fee constants are correct
        assertEq(hook.INTERNAL_POOL_FEE(), 0, "Internal fee should be 0%");
        assertEq(hook.KEEPER_POOL_FEE(), 1000, "Keeper fee should be 0.10% (1000 basis points)");
        assertEq(hook.EXTERNAL_POOL_FEE(), 5000, "External fee should be 0.50% (5000 basis points)");
    }

    function test_keeperStakingIndependentFromRewardStaking() public {
        uint256 keeperDeposit = 100e18;
        uint256 rewardStake = 50e18;
        
        // First become keeper
        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), keeperDeposit + rewardStake);
        hook.becomeKeeper(keeperDeposit);
        
        // Then stake for rewards (this should be independent)
        hook.stake(address(weth), rewardStake);
        vm.stopPrank();
        
        // Verify keeper status
        assertEq(hook.keeper(), keeper1, "Should be keeper");
        assertEq(hook.keeperDeposit(), keeperDeposit, "Keeper deposit should be separate");
        
        // Verify reward staking
        assertEq(hook.getUserStakeAmount(keeper1, address(weth)), rewardStake, "Reward stake should be separate");
        assertEq(hook.totalStakedAmount(), rewardStake, "Total staked should only include reward stakes");
        
        // Verify balances
        uint256 expectedBalance = 1000e18 - keeperDeposit - rewardStake;
        assertEq(dcaToken.balanceOf(keeper1), expectedBalance, "Balance should account for both deposits");
        
        // Contract should hold both types of deposits
        uint256 expectedContractBalance = keeperDeposit + rewardStake;
        assertEq(dcaToken.balanceOf(address(hook)), expectedContractBalance, "Hook should hold both deposits");
    }

    function test_multipleKeeperChanges() public {
        uint256 deposit1 = 100e18;
        uint256 deposit2 = 200e18;
        uint256 deposit3 = 300e18;
        
        // First keeper
        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), deposit1);
        hook.becomeKeeper(deposit1);
        vm.stopPrank();
        
        // Second keeper
        vm.startPrank(keeper2);
        dcaToken.approve(address(hook), deposit2);
        hook.becomeKeeper(deposit2);
        vm.stopPrank();
        
        // First keeper comes back with higher deposit
        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), deposit3);
        hook.becomeKeeper(deposit3);
        vm.stopPrank();
        
        // Verify final state
        assertEq(hook.keeper(), keeper1, "Final keeper should be keeper1");
        assertEq(hook.keeperDeposit(), deposit3, "Final deposit should be highest");
        
        // Verify both keepers have correct balances
        assertEq(dcaToken.balanceOf(keeper1), 1000e18 - deposit3, "Keeper1 should have paid final deposit");
        assertEq(dcaToken.balanceOf(keeper2), 1000e18, "Keeper2 should be fully refunded");
    }

    function test_getKeeperInfo() public {
        // Initially no keeper
        (address currentKeeper, uint256 currentDeposit) = hook.getKeeperInfo();
        assertEq(currentKeeper, address(0), "Initially no keeper");
        assertEq(currentDeposit, 0, "Initially no deposit");

        // Set a keeper
        uint256 deposit = 150e18;
        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), deposit);
        hook.becomeKeeper(deposit);
        vm.stopPrank();

        // Check updated info
        (currentKeeper, currentDeposit) = hook.getKeeperInfo();
        assertEq(currentKeeper, keeper1, "Should return current keeper");
        assertEq(currentDeposit, deposit, "Should return current deposit");
    }

    function test_sameKeeperIncreaseDeposit() public {
        uint256 initialDeposit = 100e18;
        uint256 increasedDeposit = 200e18;
        
        // Become keeper initially
        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), initialDeposit + increasedDeposit);
        hook.becomeKeeper(initialDeposit);
        
        // Same keeper increases deposit
        vm.expectEmit(true, true, true, true);
        emit KeeperChanged(keeper1, keeper1, increasedDeposit);
        hook.becomeKeeper(increasedDeposit);
        vm.stopPrank();
        
        // Verify final state
        assertEq(hook.keeper(), keeper1, "Should still be same keeper");
        assertEq(hook.keeperDeposit(), increasedDeposit, "Should have increased deposit");
        
        // Verify balance (should have paid net difference since they get refunded their original deposit)
        uint256 expectedBalance = 1000e18 - increasedDeposit;
        assertEq(dcaToken.balanceOf(keeper1), expectedBalance, "Should have net deposit difference");
    }
}