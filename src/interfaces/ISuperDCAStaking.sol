// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

interface ISuperDCAStaking {
    struct TokenRewardInfo {
        uint256 stakedAmount;
        uint256 lastRewardIndex;
    }

    // User actions
    function stake(address token, uint256 amount) external;
    function unstake(address token, uint256 amount) external;

    // Called by gauge on hook events
    function accrueReward(address token) external returns (uint256 rewardAmount);

    // Views
    function previewPending(address token) external view returns (uint256);
    function getUserStake(address user, address token) external view returns (uint256);
    function getUserStakedTokens(address user) external view returns (address[] memory);

    function totalStakedAmount() external view returns (uint256);
    function rewardIndex() external view returns (uint256);
    function mintRate() external view returns (uint256);
    function lastMinted() external view returns (uint256);

    function tokenRewardInfos(address token) external view returns (uint256 stakedAmount, uint256 lastRewardIndex);

    // Admin
    function setGauge(address _gauge) external;
    function setMintRate(uint256 newMintRate) external;
}
