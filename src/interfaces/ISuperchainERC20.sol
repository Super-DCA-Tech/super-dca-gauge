// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice This includes only the functions needed by the SuperDCAGauge
interface ISuperchainERC20 {
    /**
     * @notice Mints tokens to a specified address
     * @param to_ The address to mint tokens to
     * @param amount_ The amount of tokens to mint
     */
    function mint(address to_, uint256 amount_) external;

    /**
     * @notice Grants a role to an account
     * @param role The role being granted
     * @param account The account receiving the role
     */
    function grantRole(bytes32 role, address account) external;
}
