// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {ICompoundTimelock} from "@openzeppelin/contracts/vendor/compound/ICompoundTimelock.sol";

/**
 * @title SuperDCATimelock
 * @notice A timelock contract following Compound's governance style.
 *
 * The contract allows the admin to queue, cancel, and execute transactions
 * after a minimum delay. It also supports admin transfers.
 *
 * @dev This is an unaudited, ai-generated implementation of a CompoundTimelock contract.
 * @custom:security-contact mike@mikeghen.com
 */
contract SuperDCATimelock is ICompoundTimelock {
    uint256 public constant GRACE_PERIOD = 14 days;
    uint256 public constant MINIMUM_DELAY = 1 days;
    uint256 public constant MAXIMUM_DELAY = 30 days;

    address public admin;
    address public pendingAdmin;

    uint256 private _delay;

    mapping(bytes32 => bool) public override queuedTransactions;

    /**
     * @param admin_ The initial administrator.
     * @param delay_ The timelock delay in seconds.
     */
    constructor(address admin_, uint256 delay_) {
        require(delay_ >= MINIMUM_DELAY, "SuperDCATimelock::constructor: Delay must exceed minimum delay.");
        require(delay_ <= MAXIMUM_DELAY, "SuperDCATimelock::constructor: Delay must not exceed maximum delay.");
        admin = admin_;
        _delay = delay_;
    }

    // ============ Public Functions ============

    /**
     * @notice Returns the current delay value.
     */
    function delay() external view override returns (uint256) {
        return _delay;
    }

    /**
     * @notice Queues a transaction to be executed after the delay has elapsed.
     * @param target The target address for the call.
     * @param value The ETH value to send with the call.
     * @param signature The function signature to call on the target.
     * @param data The call data (if no signature is provided, data is used as-is).
     * @param eta The earliest time the transaction can be executed.
     * @return txHash The hash of the queued transaction.
     */
    function queueTransaction(
        address target,
        uint256 value,
        string calldata signature,
        bytes calldata data,
        uint256 eta
    ) external override returns (bytes32) {
        require(msg.sender == admin, "SuperDCATimelock::queueTransaction: Caller is not admin");
        require(eta >= block.timestamp + _delay, "SuperDCATimelock::queueTransaction: ETA must satisfy delay");

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        require(!queuedTransactions[txHash], "SuperDCATimelock::queueTransaction: Transaction already queued");

        queuedTransactions[txHash] = true;
        emit QueueTransaction(txHash, target, value, signature, data, eta);
        return txHash;
    }

    /**
     * @notice Cancels a previously queued transaction.
     * @param target The target address for the call.
     * @param value The ETH value to send with the call.
     * @param signature The function signature used when queuing.
     * @param data The call data.
     * @param eta The scheduled execution time of the transaction.
     */
    function cancelTransaction(
        address target,
        uint256 value,
        string calldata signature,
        bytes calldata data,
        uint256 eta
    ) external override {
        require(msg.sender == admin, "SuperDCATimelock::cancelTransaction: Caller is not admin");

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        require(queuedTransactions[txHash], "SuperDCATimelock::cancelTransaction: Transaction not queued");

        queuedTransactions[txHash] = false;
        emit CancelTransaction(txHash, target, value, signature, data, eta);
    }

    /**
     * @notice Executes a queued transaction if the time delay has elapsed.
     * @param target The target address for the call.
     * @param value The ETH value to send with the call.
     * @param signature The function signature to call on the target.
     * @param data The call data.
     * @param eta The scheduled execution time of the transaction.
     * @return returnData The data returned by the target call.
     */
    function executeTransaction(
        address target,
        uint256 value,
        string calldata signature,
        bytes calldata data,
        uint256 eta
    ) external payable override returns (bytes memory) {
        require(msg.sender == admin, "SuperDCATimelock::executeTransaction: Caller is not admin");

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        require(queuedTransactions[txHash], "SuperDCATimelock::executeTransaction: Transaction not queued");
        require(
            block.timestamp >= eta, "SuperDCATimelock::executeTransaction: Transaction hasn't surpassed time lock"
        );
        require(block.timestamp <= eta + GRACE_PERIOD, "SuperDCATimelock::executeTransaction: Transaction is stale");

        queuedTransactions[txHash] = false;

        // Prepare the call data: either use provided data or prepend the function selector.
        bytes memory callData;
        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        (bool success, bytes memory returnData) = target.call{value: value}(callData);
        require(success, "SuperDCATimelock::executeTransaction: Transaction execution reverted");

        emit ExecuteTransaction(txHash, target, value, signature, data, eta);
        return returnData;
    }

    /**
     * @notice Allows the admin to update the delay.
     * @param newDelay The new delay in seconds.
     */
    function setDelay(uint256 newDelay) external {
        require(msg.sender == admin, "SuperDCATimelock::setDelay: Caller is not admin");
        require(newDelay >= MINIMUM_DELAY, "SuperDCATimelock::setDelay: New delay must exceed minimum delay.");
        require(newDelay <= MAXIMUM_DELAY, "SuperDCATimelock::setDelay: New delay must not exceed maximum delay.");
        _delay = newDelay;
        emit NewDelay(newDelay);
    }

    /**
     * @notice Sets a new pending admin.
     * @param newPendingAdmin The address of the new pending admin.
     */
    function setPendingAdmin(address newPendingAdmin) external {
        require(msg.sender == admin, "SuperDCATimelock::setPendingAdmin: Caller is not admin");
        pendingAdmin = newPendingAdmin;
        emit NewPendingAdmin(newPendingAdmin);
    }

    /**
     * @notice Called by the pending admin to accept the admin role.
     */
    function acceptAdmin() external override {
        require(msg.sender == pendingAdmin, "SuperDCATimelock::acceptAdmin: Caller is not pending admin");
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit NewAdmin(admin);
    }

    // ============ Fallback Functions ============

    // Allows the timelock contract to receive ETH.
    receive() external payable {}
}
