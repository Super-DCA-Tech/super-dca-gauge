// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "../src/SuperDCATimelock.sol";

/**
 * @title TestTarget
 * @dev A dummy target contract used to test the execution of queued transactions.
 */
contract TestTarget {
    bool public flag;

    /// @notice Sets the flag value to true.
    function setFlag() external {
        flag = true;
    }
}

/**
 * @title SuperDCATimelockTest
 * @dev Tests for the SuperDCATimelock contract functionality.
 */
contract SuperDCATimelockTest is Test {
    SuperDCATimelock public timelock;
    TestTarget public target;
    address public admin;
    uint256 public delay;

    /**
     * @notice Set up the test by deploying the timelock and a dummy target.
     */
    function setUp() public {
        admin = vm.addr(1);
        // Choose a valid delay between MINIMUM_DELAY (1 day) and MAXIMUM_DELAY (30 days)
        delay = 2 days;
        timelock = new SuperDCATimelock(admin, delay);
        target = new TestTarget();
    }

    /**
     * @notice Helper function to compute a transaction hash.
     */
    function getTxHash(address _target, uint256 value, string memory signature, bytes memory data, uint256 eta)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_target, value, signature, data, eta));
    }

    /**
     * @notice Test that the initial delay is correctly set.
     */
    function testInitialDelay() public view {
        assertEq(timelock.delay(), delay, "Initial delay is not as expected");
    }

    /**
     * @notice Test queueing and executing a transaction.
     * It tries to execute a queued transaction too early (expecting a revert) and then
     * warps time so that the transaction is executed successfully.
     */
    function testQueueAndExecuteTransaction() public {
        uint256 eta = block.timestamp + delay + 1; // ensure eta satisfies the timelock condition

        // Queue the transaction: call TestTarget.setFlag()
        vm.prank(admin);
        bytes32 txHash = timelock.queueTransaction(address(target), 0, "setFlag()", "", eta);

        // Confirm the transaction hash is registered as queued.
        assertTrue(timelock.queuedTransactions(txHash), "Transaction was not queued");

        // Try to execute the transaction too early (should revert)
        vm.prank(admin);
        vm.expectRevert("SuperDCATimelock::executeTransaction: Transaction hasn't surpassed time lock");
        timelock.executeTransaction(address(target), 0, "setFlag()", "", eta);

        // Fast-forward time to after the eta.
        vm.warp(eta);
        // Execute the transaction.
        vm.prank(admin);
        timelock.executeTransaction(address(target), 0, "setFlag()", "", eta);

        // Verify that TestTarget.setFlag() was called.
        assertTrue(target.flag(), "Target flag was not set");

        // Verify that the transaction has been removed from the queue.
        assertFalse(timelock.queuedTransactions(txHash), "Transaction was not removed from the queue after execution");
    }

    /**
     * @notice Test that a queued transaction can be cancelled.
     */
    function testCancelTransaction() public {
        uint256 eta = block.timestamp + delay + 1;
        vm.prank(admin);
        bytes32 txHash = timelock.queueTransaction(address(target), 0, "setFlag()", "", eta);
        assertTrue(timelock.queuedTransactions(txHash), "Transaction should be queued");

        // Cancel the queued transaction.
        vm.prank(admin);
        timelock.cancelTransaction(address(target), 0, "setFlag()", "", eta);
        assertFalse(timelock.queuedTransactions(txHash), "Transaction should be cancelled");

        // Ensure executing the cancelled transaction results in revert.
        vm.prank(admin);
        vm.expectRevert("SuperDCATimelock::executeTransaction: Transaction not queued");
        timelock.executeTransaction(address(target), 0, "setFlag()", "", eta);
    }

    /**
     * @notice Test that the admin can update the delay.
     */
    function testSetDelay() public {
        uint256 newDelay = 3 days;
        vm.prank(admin);
        timelock.setDelay(newDelay);
        assertEq(timelock.delay(), newDelay, "Delay was not updated correctly");
    }

    /**
     * @notice Test transferring admin privileges using setPendingAdmin and acceptAdmin.
     */
    function testAdminTransition() public {
        address newPendingAdmin = vm.addr(2);

        // Set a new pending admin.
        vm.prank(admin);
        timelock.setPendingAdmin(newPendingAdmin);
        assertEq(timelock.pendingAdmin(), newPendingAdmin, "Pending admin not set correctly");

        // Have the pending admin accept the role.
        vm.prank(newPendingAdmin);
        timelock.acceptAdmin();

        // Verify that the admin is updated and pending admin is reset.
        assertEq(timelock.admin(), newPendingAdmin, "Admin was not updated correctly");
        assertEq(timelock.pendingAdmin(), address(0), "Pending admin was not reset");
    }
}
