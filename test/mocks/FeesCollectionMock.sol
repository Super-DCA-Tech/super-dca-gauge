// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {MockERC20Token} from "./MockERC20Token.sol";

contract FeesCollectionMock is Test {
    address public token0;
    address public token1;
    address public recipient;
    uint256 public fee0Amount;
    uint256 public fee1Amount;

    constructor(address _token0, address _token1, address _recipient, uint256 _fee0Amount, uint256 _fee1Amount) {
        token0 = _token0;
        token1 = _token1;
        recipient = _recipient;
        fee0Amount = _fee0Amount;
        fee1Amount = _fee1Amount;
    }

    function modifyLiquidities(bytes calldata, uint256) external returns (bytes4) {
        // Simulate fee collection by directly giving tokens to recipient using deal
        deal(token0, recipient, MockERC20Token(token0).balanceOf(recipient) + fee0Amount);
        deal(token1, recipient, MockERC20Token(token1).balanceOf(recipient) + fee1Amount);
        return bytes4(0x43dc74a4); // Return expected selector
    }
}
