// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

/*
    Minimal mock AgentBravoToken for testing purposes.
*/
contract MockAgentBravoToken {
    mapping(address => uint256) private _balances;
    uint256 private _totalSupply;

    // For testing, we allow anyone to call mint.
    function mint(address to, uint256 amount) public {
        _balances[to] += amount;
        _totalSupply += amount;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        require(_balances[msg.sender] >= amount, "Insufficient balance");
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }
}
