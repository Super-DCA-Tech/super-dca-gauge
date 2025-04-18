// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

interface IMsgSender {
    function msgSender() external view returns (address);
}
