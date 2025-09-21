// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title SuperDCAToken
/// @notice The Super DCA ERC20 token with permit functionality
/// @dev Extends OpenZeppelin's ERC20, Ownable and ERC20Permit contracts
contract SuperDCAToken is ERC20, Ownable, ERC20Permit {
    /// @notice Initializes the Super DCA token with name, symbol and initial supply
    /// @dev Mints initial supply to deployer
    constructor() ERC20("Super DCA", "DCA") Ownable(msg.sender) ERC20Permit("Super DCA") {
        _mint(msg.sender, 10000 * 10 ** decimals());
    }

    /// @notice Mints new tokens to a specified address
    /// @dev Can only be called by the owner
    /// @param to The address to mint tokens to
    /// @param amount The amount of tokens to mint
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}
