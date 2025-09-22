// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {OptimismIntegrationBase} from "./OptimismIntegrationBase.t.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SuperDCAStaking} from "../../src/SuperDCAStaking.sol";

/// @notice Integration tests for SuperDCAStaking on Optimism mainnet fork
contract OptimismStakingIntegration is OptimismIntegrationBase {
    /// @notice Helper function to setup a listed token for staking
    /// @param token The token address to list
    /// @param amount0 Amount of currency0 for the position
    /// @param amount1 Amount of currency1 for the position
    /// @return The pool key created for the token
    function _setupListedToken(address token, uint256 amount0, uint256 amount1) internal returns (PoolKey memory) {
        uint160 sqrtPriceX96 = _getCurrentPrice();
        (PoolKey memory key,) = _createTestPool(token, int24(60), sqrtPriceX96);
        uint256 nftId = _createFullRangePosition(key, amount0, amount1, address(this));

        IERC721(POSITION_MANAGER_V4).approve(address(listing), nftId);
        listing.list(nftId, key);

        return key;
    }

    /// @notice Helper function to perform staking operation for a user
    /// @param user The user address performing the stake
    /// @param token The token to stake into
    /// @param amount The amount to stake
    function _performStake(address user, address token, uint256 amount) internal {
        vm.startPrank(user);
        IERC20(DCA_TOKEN).approve(address(staking), amount);
        staking.stake(token, amount);
        vm.stopPrank();
    }

    /// @notice Helper function to perform unstaking operation for a user
    /// @param user The user address performing the unstake
    /// @param token The token to unstake from
    /// @param amount The amount to unstake
    function _performUnstake(address user, address token, uint256 amount) internal {
        vm.startPrank(user);
        staking.unstake(token, amount);
        vm.stopPrank();
    }

    /// @notice Helper struct to track balance state
    struct BalanceState {
        uint256 userBalance;
        uint256 stakingBalance;
    }

    /// @notice Helper function to capture balance state before operations
    /// @param user The user address to track
    /// @return Current balance state
    function _captureBalanceState(address user) internal view returns (BalanceState memory) {
        return BalanceState({
            userBalance: IERC20(DCA_TOKEN).balanceOf(user),
            stakingBalance: IERC20(DCA_TOKEN).balanceOf(address(staking))
        });
    }

    /// @notice Helper function to setup token and perform initial stake
    /// @param user The user performing the stake
    /// @param token The token to setup and stake
    /// @param amount The amount to stake
    /// @param amount0 Amount of currency0 for the position
    /// @param amount1 Amount of currency1 for the position
    /// @return The pool key created
    function _setupTokenAndStake(address user, address token, uint256 amount, uint256 amount0, uint256 amount1)
        internal
        returns (PoolKey memory)
    {
        PoolKey memory key = _setupListedToken(token, amount0, amount1);
        _performStake(user, token, amount);
        return key;
    }

    /// @notice Test successful staking of DCA tokens
    function testFork_Stake_Success() public {
        // ---- Arrange ----
        _setupListedToken(WETH, POSITION_AMOUNT0, POSITION_AMOUNT1);

        uint256 stakeAmount = STAKE_AMOUNT;
        BalanceState memory balanceBefore = _captureBalanceState(user1);

        // ---- Act ----
        vm.startPrank(user1);
        IERC20(DCA_TOKEN).approve(address(staking), stakeAmount);

        vm.expectEmit(true, true, true, true);
        emit SuperDCAStaking.Staked(WETH, user1, stakeAmount);
        staking.stake(WETH, stakeAmount);
        vm.stopPrank();

        // ---- Assert ----
        _assertStakeAmount(user1, WETH, stakeAmount);
        _assertTotalStaked(stakeAmount);

        assertEq(
            IERC20(DCA_TOKEN).balanceOf(user1), balanceBefore.userBalance - stakeAmount, "User balance should decrease"
        );
        assertEq(
            IERC20(DCA_TOKEN).balanceOf(address(staking)),
            balanceBefore.stakingBalance + stakeAmount,
            "Staking contract balance should increase"
        );

        // Check user's staked tokens list
        address[] memory stakedTokens = staking.getUserStakedTokens(user1);
        assertEq(stakedTokens.length, 1, "User should have 1 staked token");
        assertEq(stakedTokens[0], WETH, "Staked token should be WETH");
    }

    /// @notice Test staking fails for unlisted token
    function testFork_Stake_TokenNotListed() public {
        // ---- Arrange ----
        uint256 stakeAmount = STAKE_AMOUNT;
        address unlistedToken = address(0x9999);

        // ---- Act & Assert ----
        vm.startPrank(user1);
        IERC20(DCA_TOKEN).approve(address(staking), stakeAmount);

        vm.expectRevert(abi.encodeWithSignature("SuperDCAStaking__TokenNotListed()"));
        staking.stake(unlistedToken, stakeAmount);
        vm.stopPrank();
    }

    /// @notice Test staking fails with zero amount
    function testFork_Stake_ZeroAmount() public {
        // ---- Act & Assert ----
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("SuperDCAStaking__ZeroAmount()"));
        staking.stake(WETH, 0);
    }

    /// @notice Test staking fails when gauge not set
    function testFork_Stake_NoGauge() public {
        // ---- Arrange ----
        // Deploy a new staking contract without gauge set
        SuperDCAStaking newStaking = new SuperDCAStaking(DCA_TOKEN, MINT_RATE, address(this));

        uint256 stakeAmount = STAKE_AMOUNT;

        // ---- Act & Assert ----
        vm.startPrank(user1);
        IERC20(DCA_TOKEN).approve(address(newStaking), stakeAmount);

        vm.expectRevert(abi.encodeWithSignature("SuperDCAStaking__ZeroAddress()"));
        newStaking.stake(WETH, stakeAmount);
        vm.stopPrank();
    }

    /// @notice Test successful unstaking of DCA tokens
    function testFork_Unstake_Success() public {
        // ---- Arrange ----
        uint256 stakeAmount = STAKE_AMOUNT;
        uint256 unstakeAmount = stakeAmount / 2;

        _setupTokenAndStake(user1, WETH, stakeAmount, POSITION_AMOUNT0, POSITION_AMOUNT1);

        BalanceState memory balanceBefore = _captureBalanceState(user1);

        // ---- Act ----
        vm.startPrank(user1);
        vm.expectEmit(true, true, true, true);
        emit SuperDCAStaking.Unstaked(WETH, user1, unstakeAmount);
        staking.unstake(WETH, unstakeAmount);
        vm.stopPrank();

        // ---- Assert ----
        _assertStakeAmount(user1, WETH, stakeAmount - unstakeAmount);
        _assertTotalStaked(stakeAmount - unstakeAmount);

        assertEq(
            IERC20(DCA_TOKEN).balanceOf(user1),
            balanceBefore.userBalance + unstakeAmount,
            "User balance should increase"
        );
        assertEq(
            IERC20(DCA_TOKEN).balanceOf(address(staking)),
            balanceBefore.stakingBalance - unstakeAmount,
            "Staking contract balance should decrease"
        );
    }

    /// @notice Test unstaking all tokens removes from user's token set
    function testFork_UnstakeAll_RemovesFromSet() public {
        // ---- Arrange ----
        uint256 stakeAmount = STAKE_AMOUNT;
        _setupTokenAndStake(user1, WETH, stakeAmount, POSITION_AMOUNT0, POSITION_AMOUNT1);

        // ---- Act ----
        _performUnstake(user1, WETH, stakeAmount);

        // ---- Assert ----
        _assertStakeAmount(user1, WETH, 0);

        address[] memory stakedTokens = staking.getUserStakedTokens(user1);
        assertEq(stakedTokens.length, 0, "User should have no staked tokens");
    }

    /// @notice Test unstaking fails with insufficient balance
    function testFork_Unstake_InsufficientBalance() public {
        // ---- Arrange ----
        uint256 unstakeAmount = STAKE_AMOUNT;

        // ---- Act & Assert ----
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("SuperDCAStaking__InsufficientBalance()"));
        staking.unstake(WETH, unstakeAmount);
    }

    /// @notice Test unstaking fails with zero amount
    function testFork_Unstake_ZeroAmount() public {
        // ---- Act & Assert ----
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("SuperDCAStaking__ZeroAmount()"));
        staking.unstake(WETH, 0);
    }

    /// @notice Test reward index updates over time
    function testFork_RewardIndex_UpdatesOverTime() public {
        // ---- Arrange ----
        _setupTokenAndStake(user1, WETH, STAKE_AMOUNT, POSITION_AMOUNT0, POSITION_AMOUNT1);

        uint256 rewardIndexBefore = staking.rewardIndex();
        uint256 lastMintedBefore = staking.lastMinted();

        // ---- Act ----
        _simulateTimePass(3600); // 1 hour

        // Trigger reward index update by staking more
        _performStake(user2, WETH, STAKE_AMOUNT);

        // ---- Assert ----
        uint256 rewardIndexAfter = staking.rewardIndex();
        uint256 lastMintedAfter = staking.lastMinted();

        assertGt(rewardIndexAfter, rewardIndexBefore, "Reward index should increase");
        assertGt(lastMintedAfter, lastMintedBefore, "Last minted should update");
    }

    /// @notice Test reward accrual simulation
    function testFork_AccrueReward_SimulateGaugeCall() public {
        // ---- Arrange ----
        _setupTokenAndStake(user1, WETH, STAKE_AMOUNT, POSITION_AMOUNT0, POSITION_AMOUNT1);
        _simulateTimePass(3600); // 1 hour

        // ---- Act ----
        // Simulate gauge calling accrueReward
        vm.prank(address(gauge));
        uint256 rewardAmount = staking.accrueReward(WETH);

        // ---- Assert ----
        assertGt(rewardAmount, 0, "Should accrue some reward");

        // Check that subsequent call returns 0 (no time passed)
        vm.prank(address(gauge));
        uint256 secondReward = staking.accrueReward(WETH);
        assertEq(secondReward, 0, "Second immediate call should return 0");
    }

    /// @notice Test preview pending rewards
    function testFork_PreviewPending_AccurateCalculation() public {
        // ---- Arrange ----
        _setupTokenAndStake(user1, WETH, STAKE_AMOUNT, POSITION_AMOUNT0, POSITION_AMOUNT1);

        // ---- Act ----
        uint256 pendingBefore = staking.previewPending(WETH);

        _simulateTimePass(3600); // 1 hour

        uint256 pendingAfter = staking.previewPending(WETH);

        // ---- Assert ----
        assertEq(pendingBefore, 0, "Initial pending should be 0");
        assertGt(pendingAfter, 0, "Pending should increase after time");

        // Expected reward: 3600 seconds * actual mint rate from deployment
        // Mint rate in deployment: 3858024691358024 wei per second (10K tokens per month)
        // 3600 seconds * 3858024691358024 wei/second = 13,888,888,888,888,886,400 wei
        uint256 expectedReward = 3600 * staking.mintRate();
        // Allow for small rounding differences (up to 1000 wei)
        assertApproxEqAbs(pendingAfter, expectedReward, 1000, "Pending should match expected calculation");
    }

    /// @notice Test multiple users staking in same token bucket
    function testFork_MultipleUsers_SameBucket() public {
        // ---- Arrange ----
        _setupListedToken(WETH, POSITION_AMOUNT0, POSITION_AMOUNT1);

        // ---- Act ----
        _performStake(user1, WETH, STAKE_AMOUNT);
        _performStake(user2, WETH, STAKE_AMOUNT);

        // ---- Assert ----
        _assertStakeAmount(user1, WETH, STAKE_AMOUNT);
        _assertStakeAmount(user2, WETH, STAKE_AMOUNT);
        _assertTotalStaked(STAKE_AMOUNT * 2);

        (uint256 stakedAmount,) = staking.tokenRewardInfos(WETH);
        assertEq(stakedAmount, STAKE_AMOUNT * 2, "Token bucket should have total stakes");
    }

    /// @notice Test mint rate updates
    function testFork_SetMintRate_Success() public {
        // ---- Arrange ----
        uint256 newMintRate = 2e18; // 2 tokens per second

        // ---- Act ----
        vm.expectEmit(true, true, true, true);
        emit SuperDCAStaking.MintRateUpdated(newMintRate);
        staking.setMintRate(newMintRate);

        // ---- Assert ----
        assertEq(staking.mintRate(), newMintRate, "Mint rate should be updated");
    }

    /// @notice Test mint rate update by gauge
    function testFork_SetMintRate_ByGauge() public {
        // ---- Arrange ----
        uint256 newMintRate = 2e18;

        // ---- Act ----
        vm.prank(address(gauge));
        staking.setMintRate(newMintRate);

        // ---- Assert ----
        assertEq(staking.mintRate(), newMintRate, "Gauge should be able to set mint rate");
    }

    /// @notice Test mint rate update fails for unauthorized user
    function testFork_SetMintRate_NotAuthorized() public {
        // ---- Arrange ----
        uint256 newMintRate = 2e18;

        // ---- Act & Assert ----
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("SuperDCAStaking__NotAuthorized()"));
        staking.setMintRate(newMintRate);
    }

    /// @notice Test gauge setting
    function testFork_SetGauge_Success() public {
        // ---- Arrange ----
        address newGauge = makeAddr("newGauge");

        // ---- Act ----
        vm.expectEmit(true, true, true, true);
        emit SuperDCAStaking.GaugeSet(newGauge);
        staking.setGauge(newGauge);

        // ---- Assert ----
        assertEq(staking.gauge(), newGauge, "Gauge should be updated");
    }

    /// @notice Test gauge setting fails with zero address
    function testFork_SetGauge_ZeroAddress() public {
        // ---- Act & Assert ----
        vm.expectRevert(abi.encodeWithSignature("SuperDCAStaking__ZeroAddress()"));
        staking.setGauge(address(0));
    }
}
