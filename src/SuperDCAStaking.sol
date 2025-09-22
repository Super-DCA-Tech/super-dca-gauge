// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {ISuperDCAStaking} from "./interfaces/ISuperDCAStaking.sol";
import {ISuperDCAGauge} from "./interfaces/ISuperDCAGauge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SuperDCAStaking
 * @notice Manages staking mechanics and reward calculations for SuperDCA token holders.
 * @dev This contract implements a sophisticated staking system with time-based reward accrual:
 *
 *      Core Mechanics:
 *      - Users stake SuperDCA tokens into specific token "buckets" (non-DCA tokens)
 *      - Global reward index grows continuously based on time and mint rate
 *      - Individual rewards calculated as: staked_amount * (current_index - user_last_index)
 *      - Only listed tokens (verified via gauge) can receive stakes
 *
 *      Integration Architecture:
 *      - Isolated from Uniswap V4 hook for clean separation of concerns
 *      - Gauge contract calls accrueReward() during hook events
 *      - This contract handles accounting; gauge handles minting and distribution
 *      - Owner/gauge can update mint rate for dynamic reward adjustment
 *
 *      Security Features:
 *      - Token listing verification prevents staking in unlisted tokens
 *      - Per-user token set tracking for efficient queries
 *      - Authorized gauge pattern prevents unauthorized reward accrual
 *      - Mathematical precision with 1e18 scaling for reward calculations
 */
contract SuperDCAStaking is ISuperDCAStaking, Ownable2Step {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ============ Immutable Configuration ============

    /// @notice The SuperDCA token contract address used for all staking operations.
    /// @dev This token is staked by users and used for reward calculations.
    address public immutable DCA_TOKEN;

    // ============ Mutable Configuration ============

    /// @notice The authorized gauge contract address that can trigger reward accruals.
    /// @dev Only this address can call accrueReward() to maintain reward distribution integrity.
    address public gauge;

    // ============ Reward State Variables ============

    /// @notice The current mint rate used for reward index growth (tokens per second).
    /// @dev Higher mint rate means faster reward accumulation for stakers.
    uint256 public override mintRate;

    /// @notice The timestamp when the global reward index was last updated.
    /// @dev Used to calculate elapsed time for reward index growth.
    uint256 public override lastMinted;

    /// @notice The global reward index scaled by 1e18 for mathematical precision.
    /// @dev Continuously grows based on time elapsed and mint rate.
    uint256 public override rewardIndex;

    /// @notice The total amount of SuperDCA tokens currently staked across all token buckets.
    /// @dev Used as denominator in reward index calculations.
    uint256 public totalStakedAmount;

    // ============ Token and User Accounting ============

    /// @notice Maps token addresses to their reward accounting information.
    /// @dev Private mapping accessed via public view functions.
    mapping(address => TokenRewardInfo) private tokenRewardInfoOf;

    /// @notice Maps user addresses to their staked amounts per token bucket.
    /// @dev Tracks how much each user has staked in each token's bucket.
    mapping(address user => mapping(address token => uint256 amount)) public userStakes;

    /// @notice Maps user addresses to sets of tokens they have staked in.
    /// @dev Used for efficient enumeration of user's active stakes.
    mapping(address user => EnumerableSet.AddressSet) private userTokenSet;

    // ============ Events ============

    /// @notice Emitted when the authorized gauge address is updated.
    /// @param gauge The new gauge address that can call accrueReward.
    event GaugeSet(address indexed gauge);

    /// @notice Emitted when the global reward index is updated.
    /// @param newIndex The new global reward index value (scaled by 1e18).
    event RewardIndexUpdated(uint256 newIndex);

    /// @notice Emitted when a user stakes SuperDCA tokens into a token bucket.
    /// @param token The token bucket that received the stake.
    /// @param user The user who staked the tokens.
    /// @param amount The amount of SuperDCA tokens staked.
    event Staked(address indexed token, address indexed user, uint256 amount);

    /// @notice Emitted when a user unstakes SuperDCA tokens from a token bucket.
    /// @param token The token bucket from which tokens were unstaked.
    /// @param user The user who unstaked the tokens.
    /// @param amount The amount of SuperDCA tokens unstaked.
    event Unstaked(address indexed token, address indexed user, uint256 amount);

    /// @notice Emitted when the mint rate is updated by owner or gauge.
    /// @param newRate The new mint rate in tokens per second.
    event MintRateUpdated(uint256 newRate);

    // ============ Custom Errors ============

    /// @notice Thrown when a zero amount is provided where a positive amount is required.
    error SuperDCAStaking__ZeroAmount();

    /// @notice Thrown when attempting to unstake more than the available balance.
    error SuperDCAStaking__InsufficientBalance();

    /// @notice Thrown when a non-gauge address attempts to call gauge-only functions.
    error SuperDCAStaking__NotGauge();

    /// @notice Thrown when a zero address is provided where a valid address is required.
    error SuperDCAStaking__ZeroAddress();

    /// @notice Thrown when an unauthorized address attempts to perform admin actions.
    error SuperDCAStaking__NotAuthorized();

    /// @notice Thrown when attempting to stake in a token that hasn't been listed.
    error SuperDCAStaking__TokenNotListed();

    /// @notice Restricts function access to the authorized gauge contract only.
    /// @dev Used to ensure only the gauge can trigger reward accruals.
    modifier onlyGauge() {
        if (msg.sender != gauge) revert SuperDCAStaking__NotGauge();
        _;
    }

    /**
     * @notice Initializes the SuperDCAStaking contract with core configuration.
     * @dev Sets up the contract with the SuperDCA token address and initial mint rate.
     *      The lastMinted timestamp is set to current block time to start reward accrual.
     * @param _superDCAToken The ERC20 SuperDCA token address used for staking operations.
     * @param _mintRate The initial mint rate in tokens per second for reward calculations.
     * @param _owner The address that will own this contract and can perform admin functions.
     */
    constructor(address _superDCAToken, uint256 _mintRate, address _owner) Ownable(_owner) {
        if (_superDCAToken == address(0)) revert SuperDCAStaking__ZeroAddress();
        DCA_TOKEN = _superDCAToken;
        mintRate = _mintRate;
        lastMinted = block.timestamp;
    }

    /**
     * @notice Sets the authorized gauge contract address.
     * @dev Only callable by the contract owner. The gauge is the only address
     *      permitted to call accrueReward() for reward distribution integration.
     * @param _gauge The gauge contract address to authorize.
     */
    function setGauge(address _gauge) external override {
        _checkOwner();
        if (_gauge == address(0)) revert SuperDCAStaking__ZeroAddress();
        gauge = _gauge;
        emit GaugeSet(_gauge);
    }

    /**
     * @notice Updates the mint rate used for global reward index growth.
     * @dev Callable by either the contract owner or the authorized gauge for operational
     *      flexibility. Higher mint rates increase reward accumulation speed for all stakers.
     * @param newMintRate The new mint rate in tokens per second.
     */
    function setMintRate(uint256 newMintRate) external override {
        if (msg.sender != owner() && msg.sender != gauge) revert SuperDCAStaking__NotAuthorized();
        mintRate = newMintRate;
        emit MintRateUpdated(newMintRate);
    }

    // ============ Internal Accounting Functions ============

    /**
     * @notice Updates the global reward index based on elapsed time and total staked amount.
     * @dev The 1e18 scaling factor provides mathematical precision for fractional rewards.
     */
    function _updateRewardIndex() internal {
        // Return early if no stakes exist or no time has passed
        if (totalStakedAmount == 0) return;
        uint256 elapsed = block.timestamp - lastMinted;
        if (elapsed == 0) return;

        // Calculate mint amount based on elapsed time and mint rate
        uint256 mintAmount = elapsed * mintRate;

        // Update global index: previous_index + (mint_amount * 1e18 / total_staked)
        rewardIndex += Math.mulDiv(mintAmount, 1e18, totalStakedAmount);
        lastMinted = block.timestamp;
        emit RewardIndexUpdated(rewardIndex);
    }

    // ============ User Staking Functions ============

    /**
     * @notice Stakes SuperDCA tokens into a specific token bucket to earn rewards.
     * @dev Stakes earn rewards proportional to time staked and total pool activity.
     * @param token The non-DCA token identifying which bucket to stake into.
     * @param amount The amount of SuperDCA tokens to stake.
     */
    function stake(address token, uint256 amount) external override {
        // Validate amount is non-zero and gauge is set
        if (amount == 0) revert SuperDCAStaking__ZeroAmount();
        if (gauge == address(0)) revert SuperDCAStaking__ZeroAddress();

        // Verify the token is listed via gauge contract
        if (!ISuperDCAGauge(gauge).isTokenListed(token)) revert SuperDCAStaking__TokenNotListed();

        // Update global reward index to current time
        _updateRewardIndex();

        // Transfer SuperDCA tokens from user to contract
        IERC20(DCA_TOKEN).transferFrom(msg.sender, address(this), amount);

        // Update token bucket accounting and user stakes
        TokenRewardInfo storage info = tokenRewardInfoOf[token];
        info.stakedAmount += amount;
        info.lastRewardIndex = rewardIndex;

        totalStakedAmount += amount;
        userStakes[msg.sender][token] += amount;

        // Add token to user's active token set if new
        userTokenSet[msg.sender].add(token);

        emit Staked(token, msg.sender, amount);
    }

    /**
     * @notice Unstakes SuperDCA tokens from a specific token bucket.
     * @param token The non-DCA token identifying which bucket to unstake from.
     * @param amount The amount of SuperDCA tokens to unstake.
     */
    function unstake(address token, uint256 amount) external override {
        // Validate amount is non-zero and available
        if (amount == 0) revert SuperDCAStaking__ZeroAmount();

        // Check both token bucket and user balances are sufficient
        TokenRewardInfo storage info = tokenRewardInfoOf[token];
        if (info.stakedAmount < amount) revert SuperDCAStaking__InsufficientBalance();
        if (userStakes[msg.sender][token] < amount) revert SuperDCAStaking__InsufficientBalance();

        // Update global reward index to current time
        _updateRewardIndex();

        // Update token bucket accounting and user stakes
        info.stakedAmount -= amount;
        info.lastRewardIndex = rewardIndex;

        totalStakedAmount -= amount;
        userStakes[msg.sender][token] -= amount;

        // Remove token from user's set if balance reaches zero
        if (userStakes[msg.sender][token] == 0) {
            userTokenSet[msg.sender].remove(token);
        }

        // Transfer SuperDCA tokens back to user
        IERC20(DCA_TOKEN).transfer(msg.sender, amount);
        emit Unstaked(token, msg.sender, amount);
    }

    // ============ Gauge Integration Functions ============

    /**
     * @notice Calculates and returns the reward amount for a specific token bucket since last accrual.
     * @dev Only callable by the authorized gauge during Uniswap V4 hook events.
     *      The returned amount represents the portion of global rewards attributed to
     *      stakers in this specific token bucket based on their staked amounts.
     * @param token The non-DCA token bucket to calculate rewards for.
     * @return rewardAmount The amount of rewards attributed to this token bucket.
     */
    function accrueReward(address token) external override onlyGauge returns (uint256 rewardAmount) {
        // Always update the global reward index to current time
        _updateRewardIndex();

        TokenRewardInfo storage info = tokenRewardInfoOf[token];
        if (info.stakedAmount == 0) return 0;

        // Calculate reward delta for the specific token bucket
        uint256 delta = rewardIndex - info.lastRewardIndex;
        if (delta == 0) return 0;

        // Compute and return reward amount for distribution
        rewardAmount = Math.mulDiv(info.stakedAmount, delta, 1e18);

        // Update the token's last reward index to current index
        info.lastRewardIndex = rewardIndex;
        return rewardAmount;
    }

    // ============ View Functions ============

    /**
     * @notice Previews pending rewards for a token bucket without updating state.
     * @dev Simulates reward accrual by calculating what the reward would be if
     *      accrueReward() were called at the current block timestamp. This allows
     *      users and interfaces to preview rewards before actual accrual.
     * @param token The non-DCA token bucket to preview rewards for.
     * @return The calculated pending reward amount for the token bucket.
     */
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

    /**
     * @notice Returns the amount of SuperDCA tokens a user has staked in a specific token bucket.
     * @param user The user address to query.
     * @param token The token bucket to check.
     * @return The amount of SuperDCA tokens staked by the user in the specified bucket.
     */
    function getUserStake(address user, address token) external view override returns (uint256) {
        return userStakes[user][token];
    }

    /**
     * @notice Returns all token buckets where a user has active stakes.
     * @dev Uses EnumerableSet for efficient tracking of user's active token buckets.
     * @param user The user address to query.
     * @return An array of token addresses where the user has non-zero stakes.
     */
    function getUserStakedTokens(address user) external view override returns (address[] memory) {
        return userTokenSet[user].values();
    }

    /**
     * @notice Returns the reward accounting information for a specific token bucket.
     * @dev Provides access to the private tokenRewardInfoOf mapping for external queries.
     * @param token The token bucket to query.
     * @return stakedAmount The total amount of SuperDCA tokens staked in this bucket.
     * @return lastRewardIndex_ The reward index when this bucket was last updated.
     */
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
