// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.22;

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @dev A dummy implementation of IVotes for testing purposes.
contract MockVotes is IVotes {
    // Return a large enough vote count so that the proposal threshold is met.
    function getVotes(address) external pure override returns (uint256) {
        return 10000e18;
    }

    function getPastVotes(address, uint256) external pure override returns (uint256) {
        return 10000e18;
    }

    function getPastTotalSupply(uint256) external pure override returns (uint256) {
        return 100000e18;
    }

    function delegates(address) external pure override returns (address) {
        return address(0);
    }

    function delegate(address) external override {
        // dummy implementation
    }

    function delegateBySig(address, uint256, uint256, uint8, bytes32, bytes32) external override {
        // dummy implementation
    }
}
