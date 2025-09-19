// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {ISuperDCAStaking} from "./interfaces/ISuperDCAStaking.sol";
import {ISuperDCAGauge} from "./interfaces/ISuperDCAGauge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title SuperDCAStaking
/// @notice Staking and reward index accounting for Super DCA pools, isolated from the Uniswap V4 hook.
/// @dev This contract does accounting only. The Gauge is responsible for minting and donating rewards.
contract SuperDCAStaking is ISuperDCAStaking, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice The Super DCA token used for staking and accounting.
    address public immutable DCA_TOKEN;

    /// @notice The authorized Gauge (Uniswap V4 hook) allowed to call accrueReward.
    address public gauge;

    /// @notice The configured mint rate in tokens per second used for reward index growth.
    uint256 public override mintRate;
    /// @notice The last timestamp at which the global reward index was updated.
    uint256 public override lastMinted;
    /// @notice The global reward index scaled by 1e18.
    uint256 public override rewardIndex; // scaled by 1e18
    /// @notice Total amount of Super DCA tokens currently staked across all tokens.
    uint256 public totalStakedAmount;

    // Per-token reward bucket
    mapping(address => TokenRewardInfo) private tokenRewardInfoOf;

    // User stakes per token and a set of tokens per user
    mapping(address user => mapping(address token => uint256 amount)) public userStakes;
    mapping(address user => EnumerableSet.AddressSet) private userTokenSet;

    // Events
    event GaugeSet(address indexed gauge);
    event RewardIndexUpdated(uint256 newIndex);
    event Staked(address indexed token, address indexed user, uint256 amount);
    event Unstaked(address indexed token, address indexed user, uint256 amount);
    event MintRateUpdated(uint256 newRate);

    // Errors
    error SuperDCAStaking__ZeroAmount();
    error SuperDCAStaking__InsufficientBalance();
    error SuperDCAStaking__NotGauge();
    error SuperDCAStaking__ZeroAddress();
    error SuperDCAStaking__NotAuthorized();
    error SuperDCAStaking__TokenNotListed();

    modifier onlyGauge() {
        if (msg.sender != gauge) revert SuperDCAStaking__NotGauge();
        _;
    }

    /// @notice Initializes the staking contract.
    /// @param _superDCAToken The ERC20 Super DCA token used for staking.
    /// @param _mintRate The initial mint rate used for reward index growth.
    /// @param _owner The owner who can set the gauge and admin parameters.
    constructor(address _superDCAToken, uint256 _mintRate, address _owner) Ownable(_owner) {
        if (_superDCAToken == address(0)) revert SuperDCAStaking__ZeroAddress();
        DCA_TOKEN = _superDCAToken;
        mintRate = _mintRate;
        lastMinted = block.timestamp;
    }

    /// @notice Sets the authorized Gauge address.
    /// @param _gauge The Gauge address allowed to call accrueReward.
    function setGauge(address _gauge) external override onlyOwner {
        if (_gauge == address(0)) revert SuperDCAStaking__ZeroAddress();
        gauge = _gauge;
        emit GaugeSet(_gauge);
    }

    /// @notice Updates the mint rate used for reward index growth.
    /// @dev Callable by the owner (admin) or the gauge for flexibility.
    /// @param newMintRate The new mint rate in tokens per second.
    function setMintRate(uint256 newMintRate) external override {
        if (msg.sender != owner() && msg.sender != gauge) revert SuperDCAStaking__NotAuthorized();
        mintRate = newMintRate;
        emit MintRateUpdated(newMintRate);
    }

    // --- Internal accounting helpers ---
    /// @notice Updates the global reward index based on elapsed time and total stake.
    function _updateRewardIndex() internal {
        if (totalStakedAmount == 0) return;
        uint256 elapsed = block.timestamp - lastMinted;
        if (elapsed == 0) return;

        uint256 mintAmount = elapsed * mintRate;
        rewardIndex += Math.mulDiv(mintAmount, 1e18, totalStakedAmount);
        lastMinted = block.timestamp;
        emit RewardIndexUpdated(rewardIndex);
    }

    // --- User actions ---
    /// @notice Stakes Super DCA tokens into the bucket identified by `token`.
    /// @param token The non-DCA token whose pool bucket is being staked into.
    /// @param amount The amount of Super DCA tokens to stake.
    function stake(address token, uint256 amount) external override {
        if (amount == 0) revert SuperDCAStaking__ZeroAmount();
        if (gauge == address(0)) revert SuperDCAStaking__ZeroAddress();
        // Verify token is listed in the gauge
        if (!ISuperDCAGauge(gauge).isTokenListed(token)) revert SuperDCAStaking__TokenNotListed();
        _updateRewardIndex();

        IERC20(DCA_TOKEN).transferFrom(msg.sender, address(this), amount);

        TokenRewardInfo storage info = tokenRewardInfoOf[token];
        info.stakedAmount += amount;
        info.lastRewardIndex = rewardIndex;

        totalStakedAmount += amount;
        userStakes[msg.sender][token] += amount;
        userTokenSet[msg.sender].add(token);

        emit Staked(token, msg.sender, amount);
    }

    /// @notice Unstakes previously staked Super DCA tokens from the `token` bucket.
    /// @param token The non-DCA token whose pool bucket is being unstaked from.
    /// @param amount The amount of Super DCA tokens to unstake.
    function unstake(address token, uint256 amount) external override {
        if (amount == 0) revert SuperDCAStaking__ZeroAmount();

        TokenRewardInfo storage info = tokenRewardInfoOf[token];
        if (info.stakedAmount < amount) revert SuperDCAStaking__InsufficientBalance();
        if (userStakes[msg.sender][token] < amount) revert SuperDCAStaking__InsufficientBalance();

        _updateRewardIndex();

        info.stakedAmount -= amount;
        info.lastRewardIndex = rewardIndex;

        totalStakedAmount -= amount;
        userStakes[msg.sender][token] -= amount;
        if (userStakes[msg.sender][token] == 0) {
            userTokenSet[msg.sender].remove(token);
        }

        IERC20(DCA_TOKEN).transfer(msg.sender, amount);
        emit Unstaked(token, msg.sender, amount);
    }

    // --- Hook integration ---
    /// @notice Accrues and returns the reward amount attributed to `token` since last accrual.
    /// @dev Only callable by the authorized Gauge during hook events.
    /// @param token The non-DCA token bucket for which to accrue rewards.
    /// @return rewardAmount The reward amount attributed to `token`.
    function accrueReward(address token) external override onlyGauge returns (uint256 rewardAmount) {
        // Always update the global reward index; lastMinted should advance during hook events
        _updateRewardIndex();

        TokenRewardInfo storage info = tokenRewardInfoOf[token];
        if (info.stakedAmount == 0) return 0;

        uint256 delta = rewardIndex - info.lastRewardIndex;
        if (delta == 0) return 0;

        rewardAmount = Math.mulDiv(info.stakedAmount, delta, 1e18);
        info.lastRewardIndex = rewardIndex;
        return rewardAmount;
    }

    // --- Views ---
    /// @notice Previews the pending reward for `token` as if accrual occurred now.
    /// @param token The non-DCA token bucket to preview.
    /// @return The computed pending reward amount.
    function previewPending(address token) external view override returns (uint256) {
        TokenRewardInfo storage info = tokenRewardInfoOf[token];
        if (info.stakedAmount == 0 || totalStakedAmount == 0) return 0;

        uint256 currentIndex = rewardIndex;
        uint256 elapsed = block.timestamp - lastMinted;
        if (elapsed > 0) {
            uint256 mintAmount = elapsed * mintRate;
            currentIndex += Math.mulDiv(mintAmount, 1e18, totalStakedAmount);
        }
        return Math.mulDiv(info.stakedAmount, currentIndex - info.lastRewardIndex, 1e18);
    }

    /// @notice Returns the user's staked amount in a given token bucket.
    function getUserStake(address user, address token) external view override returns (uint256) {
        return userStakes[user][token];
    }

    /// @notice Returns the list of token buckets where the user has a non-zero stake.
    function getUserStakedTokens(address user) external view override returns (address[] memory) {
        return userTokenSet[user].values();
    }

    /// @notice Returns the total Super DCA staked across all token buckets.
    function totalStaked() external view override returns (uint256) {
        return totalStakedAmount;
    }

    /// @notice Returns the per-token reward info.
    function tokenRewardInfos(address token)
        external
        view
        override
        returns (uint256 stakedAmount, uint256 lastRewardIndex_)
    {
        TokenRewardInfo storage info = tokenRewardInfoOf[token];
        return (info.stakedAmount, info.lastRewardIndex);
    }
}
