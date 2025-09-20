// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {ISuperDCAStaking} from "src/interfaces/ISuperDCAStaking.sol";

contract FakeStaking is ISuperDCAStaking {
    function stake(address, uint256) external {}
    function unstake(address, uint256) external {}

    function accrueReward(address) external pure returns (uint256 rewardAmount) {
        return 0;
    }

    function previewPending(address) external pure returns (uint256) {
        return 0;
    }

    function getUserStake(address, address) external pure returns (uint256) {
        return 0;
    }

    function getUserStakedTokens(address) external pure returns (address[] memory) {
        address[] memory empty;
        return empty;
    }

    function totalStakedAmount() external pure returns (uint256) {
        return 0;
    }

    function rewardIndex() external pure returns (uint256) {
        return 0;
    }

    function mintRate() external pure returns (uint256) {
        return 0;
    }

    function lastMinted() external pure returns (uint256) {
        return 0;
    }

    function tokenRewardInfos(address) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function setGauge(address) external {}
    function setMintRate(uint256) external {}
}
