// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.22;

import {ICompoundTimelock} from "@openzeppelin/contracts/vendor/compound/ICompoundTimelock.sol";

/// @dev A dummy implementation of ICompoundTimelock for testing purposes.
contract MockCompoundTimelock is ICompoundTimelock {
    function delay() external pure override returns (uint256) {
        return 0;
    }

    function queueTransaction(address, uint256, string calldata, bytes calldata, uint256)
        external
        pure
        override
        returns (bytes32)
    {
        return keccak256(bytes("dummy"));
    }

    function executeTransaction(address, uint256, string calldata, bytes calldata, uint256)
        external
        payable
        override
        returns (bytes memory)
    {
        return "";
    }

    function cancelTransaction(address, uint256, string calldata, bytes calldata, uint256) external pure override {
        // nothing to do here
    }

    receive() external payable override {}

    function GRACE_PERIOD() external pure override returns (uint256) {
        return 0;
    }

    function MINIMUM_DELAY() external pure override returns (uint256) {
        return 0;
    }

    function MAXIMUM_DELAY() external pure override returns (uint256) {
        return 0;
    }

    function acceptAdmin() external override {}

    function admin() external pure override returns (address) {
        return address(0);
    }

    function pendingAdmin() external pure override returns (address) {
        return address(0);
    }

    function queuedTransactions(bytes32) external pure override returns (bool) {
        return false;
    }

    function setDelay(uint256) external override {}

    function setPendingAdmin(address) external override {}
}
