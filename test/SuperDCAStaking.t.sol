// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {SuperDCAStaking} from "../src/SuperDCAStaking.sol";
import {MockERC20Token} from "./mocks/MockERC20Token.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract SuperDCAStakingTest is Test {
    SuperDCAStaking staking;
    MockERC20Token dca;
    address admin;
    address gauge;
    address user;
    address tokenA;
    address tokenB;
    uint256 rate;

    function setUp() public virtual {
        admin = makeAddr("Admin");
        gauge = makeAddr("Gauge");
        user = makeAddr("User");
        tokenA = address(0x1111);
        tokenB = address(0x2222);
        rate = 100;

        dca = new MockERC20Token("Super DCA", "SDCA", 18);
        staking = new SuperDCAStaking(address(dca), rate, admin);
        vm.prank(admin);
        staking.setGauge(gauge);

        _mintAndApprove(user, 1_000e18);

        // Mock token listing checks on the gauge for commonly used tokens
        bytes4 IS_TOKEN_LISTED = bytes4(keccak256("isTokenListed(address)"));
        vm.mockCall(gauge, abi.encodeWithSelector(IS_TOKEN_LISTED, tokenA), abi.encode(true));
        vm.mockCall(gauge, abi.encodeWithSelector(IS_TOKEN_LISTED, tokenB), abi.encode(true));
    }

    function _boundPositiveAmount(uint256 amt, uint256 max) internal pure returns (uint256) {
        return bound(amt, 1, max);
    }

    // Helpers
    function _mintAndApprove(address who, uint256 amt) internal {
        dca.mint(who, amt);
        vm.prank(who);
        dca.approve(address(staking), type(uint256).max);
    }

    function _stake(address who, address token, uint256 amt) internal {
        vm.prank(who);
        staking.stake(token, amt);
    }

    function _unstake(address who, address token, uint256 amt) internal {
        vm.prank(who);
        staking.unstake(token, amt);
    }
}

contract Constructor is SuperDCAStakingTest {
    function test_SetsConfigurationParameters() public view {
        assertEq(address(staking.DCA_TOKEN()), address(dca));
        assertEq(staking.mintRate(), rate);
        assertEq(staking.lastMinted(), block.timestamp);
        assertEq(staking.rewardIndex(), 0);
        assertEq(staking.totalStakedAmount(), 0);
        assertEq(staking.owner(), admin);
    }

    function testFuzz_RevertIf_SuperDcaTokenIsZero(address _owner) public {
        vm.assume(_owner != address(0));
        vm.expectRevert(SuperDCAStaking.SuperDCAStaking__ZeroAddress.selector);
        new SuperDCAStaking(address(0), rate, _owner);
    }

    function testFuzz_SetsArbitraryValues(address _owner, uint256 _rate) public {
        vm.assume(_owner != address(0));
        SuperDCAStaking s = new SuperDCAStaking(address(dca), _rate, _owner);
        assertEq(s.owner(), _owner);
        assertEq(s.mintRate(), _rate);
        assertEq(address(s.DCA_TOKEN()), address(dca));
    }
}

contract SetGauge is SuperDCAStakingTest {
    function testFuzz_SetsGaugeWhenCalledByOwner(address _gauge) public {
        vm.assume(_gauge != address(0));
        vm.prank(admin);
        vm.expectEmit();
        emit SuperDCAStaking.GaugeSet(_gauge);
        staking.setGauge(_gauge);
        assertEq(staking.gauge(), _gauge);
    }

    function test_RevertIf_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(SuperDCAStaking.SuperDCAStaking__ZeroAddress.selector);
        staking.setGauge(address(0));
    }

    function testFuzz_RevertIf_CallerIsNotOwner(address _caller, address _gauge) public {
        vm.assume(_caller != admin);
        vm.assume(_gauge != address(0));
        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
        staking.setGauge(_gauge);
    }
}

contract SetMintRate is SuperDCAStakingTest {
    function testFuzz_UpdatesMintRateWhenCalledByOwner(uint256 _newRate) public {
        vm.prank(admin);
        vm.expectEmit();
        emit SuperDCAStaking.MintRateUpdated(_newRate);
        staking.setMintRate(_newRate);
        assertEq(staking.mintRate(), _newRate);
    }

    function testFuzz_RevertIf_CallerIsNotOwner(address _caller, uint256 _newRate) public {
        vm.assume(_caller != admin);
        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
        staking.setMintRate(_newRate);
    }

    /**
     * @notice Tests that setMintRate applies old rewards before changing rate.
     * @dev This validates the invariant that past time is priced at the old rate.
     *      Without _updateRewardIndex() call, past interval would be priced at new rate.
     */
    function test_AppliesOldRateToElapsedTimeBeforeRateChange() public {
        // Stake tokens to enable reward accrual
        _stake(user, tokenA, 100e18);

        uint256 oldRate = staking.mintRate(); // 100 per second
        uint256 elapsed = 1000; // 1000 seconds pass
        uint256 newRate = 1000; // Change to 1000 per second

        // Advance time without triggering any update
        vm.warp(block.timestamp + elapsed);

        // Capture state before rate change
        uint256 lastMintedBefore = staking.lastMinted();
        uint256 rewardIndexBefore = staking.rewardIndex();

        // Change the rate - should apply old rate to elapsed time first
        vm.prank(admin);
        staking.setMintRate(newRate);

        // After setMintRate, lastMinted should be updated to current time
        assertEq(staking.lastMinted(), block.timestamp, "lastMinted should be updated");

        // Calculate expected reward using OLD rate for the elapsed period
        uint256 expectedMintAmount = elapsed * oldRate; // 1000 * 100 = 100,000
        uint256 totalStaked = staking.totalStakedAmount();
        uint256 expectedIndexIncrease = (expectedMintAmount * 1e18) / totalStaked;
        uint256 expectedNewIndex = rewardIndexBefore + expectedIndexIncrease;

        // Verify the reward index was updated with the old rate
        assertEq(staking.rewardIndex(), expectedNewIndex, "rewardIndex should reflect old rate");

        // Verify new rate is set
        assertEq(staking.mintRate(), newRate, "mintRate should be updated to new rate");
    }

    /**
     * @notice Tests reward calculation after rate change uses correct rates for each period.
     * @dev Validates that rewards before rate change use old rate, and after use new rate.
     */
    function test_RewardsUseCorrectRateForEachTimePeriod() public {
        // Setup: User stakes tokens
        _stake(user, tokenA, 100e18);

        uint256 oldRate = 10; // 10 tokens per second
        vm.prank(admin);
        staking.setMintRate(oldRate);

        // Period 1: 1000 seconds at old rate
        uint256 period1Duration = 1000;
        vm.warp(block.timestamp + period1Duration);

        // Change rate - this should apply old rate to period 1
        uint256 newRate = 1000; // 1000 tokens per second
        vm.prank(admin);
        staking.setMintRate(newRate);

        uint256 indexAfterRateChange = staking.rewardIndex();

        // Period 2: Another 1000 seconds at new rate
        uint256 period2Duration = 1000;
        vm.warp(block.timestamp + period2Duration);

        // Accrue rewards to apply period 2
        vm.prank(gauge);
        uint256 accrued = staking.accrueReward(tokenA);

        // Calculate expected rewards:
        // Period 1: 1000 seconds * 10 rate = 10,000 tokens for 100e18 staked
        // Period 2: 1000 seconds * 1000 rate = 1,000,000 tokens for 100e18 staked
        // Total expected: 10,000 + 1,000,000 = 1,010,000

        uint256 expectedPeriod1 = period1Duration * oldRate; // 10,000
        uint256 expectedPeriod2 = period2Duration * newRate; // 1,000,000
        uint256 expectedTotal = expectedPeriod1 + expectedPeriod2; // 1,010,000

        assertEq(accrued, expectedTotal, "Total rewards should use old rate for period 1 and new rate for period 2");
    }
}

contract Stake is SuperDCAStakingTest {
    function testFuzz_UpdatesState(uint256 _amount) public {
        _amount = bound(_amount, 1, dca.balanceOf(user));
        uint256 beforeBal = dca.balanceOf(user);
        vm.prank(user);
        staking.stake(tokenA, _amount);
        (uint256 stakedAmount, uint256 lastIndex) = staking.tokenRewardInfos(tokenA);
        assertEq(stakedAmount, _amount);
        assertEq(lastIndex, staking.rewardIndex());
        assertEq(staking.totalStakedAmount(), _amount);
        assertEq(staking.getUserStake(user, tokenA), _amount);
        assertEq(staking.getUserStakedTokens(user).length, 1);
        assertEq(dca.balanceOf(user), beforeBal - _amount);
    }

    function test_FirstStakerCannotHarvestBankedTime() public {
        // Record the initial deployment time
        uint256 deployTime = staking.lastMinted();

        // Simulate time passing after deployment (e.g., 1000 seconds with no stakes)
        uint256 emptyPeriod = 1000;
        vm.warp(deployTime + emptyPeriod);

        // First user stakes tokens (simulating flash loan borrowing)
        vm.prank(user);
        staking.stake(tokenA, 100e18);

        // Verify that lastMinted was updated during stake, not staying at deployTime
        assertEq(staking.lastMinted(), deployTime + emptyPeriod, "lastMinted should be updated to current time");

        // Immediately trigger reward accrual (simulating pool swap in the attack)
        vm.prank(gauge);
        uint256 accrued = staking.accrueReward(tokenA);

        // The accrued rewards should be 0 or very minimal, NOT based on the empty period
        // Since no time passed between stake and accrual, rewards should be 0
        assertEq(accrued, 0, "No rewards should accrue from empty period before first stake");

        // Verify the user cannot harvest rewards from the empty period
        (uint256 stakedAmount, uint256 lastRewardIndex) = staking.tokenRewardInfos(tokenA);
        assertEq(stakedAmount, 100e18);
        assertEq(lastRewardIndex, staking.rewardIndex(), "Token reward index should match global index");
    }

    function testFuzz_EmitsStakedEvent(uint256 _amount) public {
        _amount = bound(_amount, 1, dca.balanceOf(user));
        vm.prank(user);
        vm.expectEmit();
        emit SuperDCAStaking.Staked(tokenA, user, _amount);
        staking.stake(tokenA, _amount);
    }

    function testFuzz_RevertIf_ZeroAmountStake(uint256 _amount) public {
        _amount = 0;
        vm.prank(user);
        vm.expectRevert(SuperDCAStaking.SuperDCAStaking__ZeroAmount.selector);
        staking.stake(tokenA, _amount);
    }
}

contract Unstake is SuperDCAStakingTest {
    function setUp() public override {
        SuperDCAStakingTest.setUp();
        _stake(user, tokenA, 100e18);
    }

    function testFuzz_UpdatesState(uint256 _amount) public {
        _amount = bound(_amount, 1, staking.getUserStake(user, tokenA));
        uint256 beforeBal = dca.balanceOf(user);
        uint256 beforeTotal = staking.totalStakedAmount();
        vm.prank(user);
        staking.unstake(tokenA, _amount);
        (uint256 stakedAmount,) = staking.tokenRewardInfos(tokenA);
        assertEq(stakedAmount, 100e18 - _amount);
        assertEq(staking.totalStakedAmount(), beforeTotal - _amount);
        assertEq(staking.getUserStake(user, tokenA), 100e18 - _amount);
        assertEq(dca.balanceOf(user), beforeBal + _amount);
    }

    function testFuzz_EmitsUnstakedEvent(uint256 _amount) public {
        _amount = bound(_amount, 1, staking.getUserStake(user, tokenA));
        vm.prank(user);
        vm.expectEmit();
        emit SuperDCAStaking.Unstaked(tokenA, user, _amount);
        staking.unstake(tokenA, _amount);
    }

    function testFuzz_RevertIf_ZeroAmountUnstake() public {
        vm.prank(user);
        vm.expectRevert(SuperDCAStaking.SuperDCAStaking__ZeroAmount.selector);
        staking.unstake(tokenA, 0);
    }

    function testFuzz_RevertIf_UnstakeExceedsTokenBucket(uint256 _amount) public {
        _amount = bound(_amount, 100e18 + 1, type(uint256).max);
        vm.prank(user);
        vm.expectRevert(SuperDCAStaking.SuperDCAStaking__InsufficientBalance.selector);
        staking.unstake(tokenA, _amount);
    }

    function testFuzz_RevertIf_UnstakeExceedsUserStake(uint256 _amount) public {
        address other = makeAddr("Other");
        _mintAndApprove(other, 1_000e18);
        vm.startPrank(other);
        staking.stake(tokenA, 10e18);
        _amount = bound(_amount, 11e18, type(uint256).max);
        vm.expectRevert(SuperDCAStaking.SuperDCAStaking__InsufficientBalance.selector);
        staking.unstake(tokenA, _amount);
        vm.stopPrank();
    }
}

contract AccrueReward is SuperDCAStakingTest {
    function setUp() public override {
        SuperDCAStakingTest.setUp();
        vm.startPrank(user);
        staking.stake(tokenA, 100e18);
        staking.stake(tokenB, 300e18);
        vm.stopPrank();
    }

    function testFuzz_ComputesAccruedAndUpdatesIndex(uint256 _extra) public {
        _extra = _boundPositiveAmount(_extra, 365 days);
        uint256 start = staking.lastMinted();
        vm.warp(start + _extra);
        uint256 totalMint = _extra * rate;
        uint256 beforeIndex = staking.rewardIndex();
        uint256 total = staking.totalStakedAmount();
        uint256 expectedIndex = beforeIndex + (totalMint * 1e18) / total;
        vm.prank(gauge);
        uint256 accruedA = staking.accrueReward(tokenA);
        uint256 expectedA = (100e18 * (expectedIndex - beforeIndex)) / 1e18;
        assertEq(accruedA, expectedA);
    }

    function testFuzz_EmitsRewardIndexUpdatedOnAccrual(uint256 _extra) public {
        _extra = _boundPositiveAmount(_extra, 365 days);
        uint256 start = staking.lastMinted();
        vm.warp(start + _extra);
        uint256 beforeIndex = staking.rewardIndex();
        uint256 total = staking.totalStakedAmount();
        uint256 minted = _extra * rate;
        uint256 expectedIndex = beforeIndex + (minted * 1e18) / total;
        vm.prank(gauge);
        vm.expectEmit();
        emit SuperDCAStaking.RewardIndexUpdated(expectedIndex);
        staking.accrueReward(tokenA);
    }

    function testFuzz_RevertIf_CallerIsNotGauge(address _caller) public {
        vm.assume(_caller != gauge);
        vm.prank(_caller);
        vm.expectRevert(SuperDCAStaking.SuperDCAStaking__NotGauge.selector);
        staking.accrueReward(tokenA);
    }
}

contract PreviewPending is SuperDCAStakingTest {
    function setUp() public override {
        SuperDCAStakingTest.setUp();
        vm.prank(user);
        staking.stake(tokenA, 100e18);
    }

    function testFuzz_ComputesPending(uint256 _extra) public {
        _extra = _boundPositiveAmount(_extra, 365 days);
        uint256 start = staking.lastMinted();
        vm.warp(start + _extra);
        uint256 totalMint = _extra * rate;
        uint256 expectedA = (totalMint * 100e18) / 100e18;
        assertEq(staking.previewPending(tokenA), expectedA);
    }

    function test_ReturnsZeroWhen_NoStake() public {
        vm.prank(user);
        staking.unstake(tokenA, 100e18);
        assertEq(staking.previewPending(tokenA), 0);
    }

    function test_ReturnsZeroWhen_NoTimeElapsed() public view {
        assertEq(staking.previewPending(tokenA), 0);
    }
}

contract GetUserStakedTokens is SuperDCAStakingTest {
    function test_ReturnsTokensAfterStake() public {
        vm.startPrank(user);
        staking.stake(tokenA, 10);
        staking.stake(tokenB, 10);
        vm.stopPrank();
        address[] memory tokens = staking.getUserStakedTokens(user);
        assertEq(tokens.length, 2);
        assertEq(tokens[0], tokenA);
        assertEq(tokens[1], tokenB);
    }

    function test_ReturnsEmptyWhen_NoStake() public view {
        address[] memory tokens = staking.getUserStakedTokens(user);
        assertEq(tokens.length, 0);
    }
}

contract GetUserStake is SuperDCAStakingTest {
    function test_ReturnsAmountAfterStake() public {
        vm.prank(user);
        staking.stake(tokenA, 123);
        assertEq(staking.getUserStake(user, tokenA), 123);
    }

    function test_ReturnsZeroWhen_NoStake() public view {
        assertEq(staking.getUserStake(user, tokenA), 0);
    }
}

contract TotalStaked is SuperDCAStakingTest {
    function test_UpdatesAfterStakeAndUnstake() public {
        vm.startPrank(user);
        staking.stake(tokenA, 50);
        staking.stake(tokenB, 70);
        staking.unstake(tokenA, 20);
        vm.stopPrank();
        assertEq(staking.totalStakedAmount(), 100);
    }
}

contract TokenRewardInfos is SuperDCAStakingTest {
    function test_ReturnsZeroStructInitially() public view {
        (uint256 stakedAmount, uint256 lastIndex) = staking.tokenRewardInfos(tokenA);
        assertEq(stakedAmount, 0);
        assertEq(lastIndex, 0);
    }

    function test_ReturnsUpdatedStructAfterStake() public {
        vm.prank(user);
        staking.stake(tokenA, 42);
        (uint256 stakedAmount, uint256 lastIndex) = staking.tokenRewardInfos(tokenA);
        assertEq(stakedAmount, 42);
        assertEq(lastIndex, staking.rewardIndex());
    }

    function test_PoC_UnstakeBeforeAccrue_PreservesRewards() public {
        // Set up a single bucket stake
        vm.prank(user);
        staking.stake(tokenA, 100e18);
        // Let rewards accrue
        uint256 start = staking.lastMinted();
        uint256 secs = 100;
        vm.warp(start + secs);
        //what should be paid
        uint256 expectedMint = secs * rate;
        assertGt(expectedMint, 0, "sanity");
        // Unstake before accrue - rewards should be preserved now
        vm.prank(user);
        staking.unstake(tokenA, 1);
        // Accrue now => should pay expected rewards despite unstake
        vm.prank(gauge);
        uint256 paid = staking.accrueReward(tokenA);
        assertEq(paid, expectedMint, "pending bucket rewards should be preserved");
    }

    function test_StakeBeforeAccrue_PreservesRewards() public {
        // Set up a single bucket stake
        vm.prank(user);
        staking.stake(tokenA, 100e18);
        // Let rewards accrue
        uint256 start = staking.lastMinted();
        uint256 secs = 100;
        vm.warp(start + secs);
        //what should be paid
        uint256 expectedMint = secs * rate;
        assertGt(expectedMint, 0, "sanity");
        // Stake more before accrue - rewards should be preserved now
        vm.prank(user);
        staking.stake(tokenA, 50e18);
        // Accrue now => should pay expected rewards despite additional stake
        vm.prank(gauge);
        uint256 paid = staking.accrueReward(tokenA);
        assertEq(paid, expectedMint, "pending bucket rewards should be preserved after stake");
    }

    function test_MultipleStakeUnstakeBeforeAccrue_PreservesRewards() public {
        // Set up initial stake
        vm.prank(user);
        staking.stake(tokenA, 100e18);

        // Let rewards accrue for 50 seconds
        uint256 start = staking.lastMinted();
        vm.warp(start + 50);

        // Stake more (should accumulate pending rewards from first period)
        vm.prank(user);
        staking.stake(tokenA, 50e18);

        // Let more rewards accrue for another 50 seconds with 150e18 total staked
        vm.warp(start + 100);

        // Unstake some (should accumulate pending rewards again)
        vm.prank(user);
        staking.unstake(tokenA, 25e18);

        // Accrue should pay all accumulated rewards
        // Period 1: 100e18 staked, 50 seconds = 5000 rewards
        // Period 2: 150e18 staked, 50 seconds = 5000 rewards minted -> index increases by (5000 * 1e18 / 150e18) = 33
        //           150e18 * 33 / 1e18 = 4950 rewards
        // Total: 5000 + 4950 = 9950 (with rounding)
        vm.prank(gauge);
        uint256 paid = staking.accrueReward(tokenA);
        assertEq(paid, 9950, "all pending rewards should be preserved (with rounding)");
    }

    function test_AccrueMultipleTimes_ResetsPendingRewards() public {
        // Set up stake and let rewards accrue
        vm.prank(user);
        staking.stake(tokenA, 100e18);
        vm.warp(staking.lastMinted() + 50);

        // First accrue
        vm.prank(gauge);
        uint256 firstAccrue = staking.accrueReward(tokenA);
        assertGt(firstAccrue, 0, "first accrue should have rewards");

        // Immediate second accrue should return 0
        vm.prank(gauge);
        uint256 secondAccrue = staking.accrueReward(tokenA);
        assertEq(secondAccrue, 0, "second immediate accrue should return 0");

        // Let more time pass
        vm.warp(block.timestamp + 50);

        // Third accrue should have new rewards
        vm.prank(gauge);
        uint256 thirdAccrue = staking.accrueReward(tokenA);
        assertGt(thirdAccrue, 0, "third accrue after time should have rewards");
    }

    function test_PreviewPending_IncludesAccumulatedRewards() public {
        // Set up stake
        vm.prank(user);
        staking.stake(tokenA, 100e18);
        vm.warp(staking.lastMinted() + 50);

        // Preview should show pending rewards
        uint256 preview1 = staking.previewPending(tokenA);
        assertGt(preview1, 0, "preview should show pending rewards");

        // Stake more (accumulates pending rewards)
        vm.prank(user);
        staking.stake(tokenA, 50e18);

        // Preview should still show the accumulated rewards
        uint256 preview2 = staking.previewPending(tokenA);
        assertGe(preview2, preview1, "preview should include accumulated rewards");
    }
}
