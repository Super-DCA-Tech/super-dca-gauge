// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

contract MockERC20Token {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;

    // ----------------------------------
    // Ownership (Ownable lite)
    // ----------------------------------
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "MockERC20Token: caller is not the owner");
        _;
    }

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public lastParam__transfer_to;
    uint256 public lastParam__transfer_amount;
    bool public shouldRevertOnNextCall;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;

        owner = msg.sender;
    }

    function __setShouldRevertOnNextCall(bool _shouldRevert) external {
        shouldRevertOnNextCall = _shouldRevert;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address _to, uint256 _amount) external returns (bool) {
        require(!shouldRevertOnNextCall, "MockERC20Token: Revert Requested");
        require(balanceOf[msg.sender] >= _amount, "MockERC20Token: Insufficient balance");

        balanceOf[msg.sender] -= _amount;
        balanceOf[_to] += _amount;

        lastParam__transfer_amount = _amount;
        lastParam__transfer_to = _to;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(!shouldRevertOnNextCall, "MockERC20Token: Revert Requested");
        require(balanceOf[from] >= amount, "MockERC20Token: Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "MockERC20Token: Insufficient allowance");

        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        // Only the owner can mint new tokens
        require(msg.sender == owner, "MockERC20Token: caller is not the owner");

        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "MockERC20Token: new owner is the zero address");
        owner = newOwner;
    }
}
