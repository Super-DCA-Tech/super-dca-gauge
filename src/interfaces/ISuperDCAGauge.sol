// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

interface ISuperDCAGauge {
    function isTokenListed(address token) external view returns (bool);
}
