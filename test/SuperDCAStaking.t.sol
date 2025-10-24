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

    function testFuzz_UpdatesMintRateWhenCalledByGauge(uint256 _newRate) public {
        vm.prank(gauge);
        vm.expectEmit();
        emit SuperDCAStaking.MintRateUpdated(_newRate);
        staking.setMintRate(_newRate);
        assertEq(staking.mintRate(), _newRate);
    }

    function testFuzz_RevertIf_CallerIsNotOwnerOrGauge(address _caller, uint256 _newRate) public {
        vm.assume(_caller != admin && _caller != gauge);
        vm.prank(_caller);
        vm.expectRevert(SuperDCAStaking.SuperDCAStaking__NotAuthorized.selector);
        staking.setMintRate(_newRate);
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
}

contract FirstDepositorFlashLoanVulnerability is SuperDCAStakingTest {
    /**
     * @notice Tests that the fix prevents the flash loan attack by advancing lastMinted during empty periods
     * @dev This simulates the attack path described in M-1:
     *      1. Time passes after contract deployment
     *      2. First depositor stakes (when totalStakedAmount == 0)
     *      3. Depositor triggers accrueReward
     *      Without the fix, the depositor would claim all rewards from deployment time
     *      With the fix, lastMinted is advanced when staking, preventing reward banking
     */
    function test_FirstStakeAdvancesLastMintedToPreventRewardBanking() public {
        // Record initial deployment time
        uint256 deploymentTime = staking.lastMinted();
        
        // Simulate time passing after deployment (e.g., 30 days)
        uint256 timeElapsed = 30 days;
        vm.warp(block.timestamp + timeElapsed);
        
        // Record the time before first stake
        uint256 timeBeforeStake = block.timestamp;
        
        // First user stakes tokens (totalStakedAmount is 0 before this)
        vm.prank(user);
        staking.stake(tokenA, 100e18);
        
        // Verify lastMinted was advanced during the stake transaction
        // With the fix, lastMinted should now be at the stake time, not deployment time
        assertEq(staking.lastMinted(), timeBeforeStake, "lastMinted should advance to current time during first stake");
        assertGt(staking.lastMinted(), deploymentTime, "lastMinted should be greater than deployment time");
        
        // Now simulate a swap that triggers accrueReward (after a short delay)
        vm.warp(block.timestamp + 1 hours);
        
        vm.prank(gauge);
        uint256 reward = staking.accrueReward(tokenA);
        
        // Calculate expected reward: only for the 1 hour since stake, not the 30 days since deployment
        uint256 expectedReward = 1 hours * rate;
        
        // Verify the reward is only for time after stake, not banked time
        assertEq(reward, expectedReward, "Reward should only accrue from stake time, not deployment time");
        
        // Verify the attacker cannot claim 30 days worth of rewards
        uint256 bankedReward = timeElapsed * rate;
        assertLt(reward, bankedReward, "Reward should be much less than banked reward from empty period");
    }

    /**
     * @notice Tests that multiple empty periods don't accumulate rewards
     */
    function test_MultipleEmptyPeriodsDoNotAccumulateRewards() public {
        uint256 deploymentTime = staking.lastMinted();
        
        // First empty period: 10 days
        vm.warp(block.timestamp + 10 days);
        
        // Someone stakes
        vm.prank(user);
        staking.stake(tokenA, 50e18);
        uint256 firstStakeTime = block.timestamp;
        
        // They unstake immediately
        vm.prank(user);
        staking.unstake(tokenA, 50e18);
        
        // Second empty period: 20 days (totalStakedAmount is back to 0)
        vm.warp(block.timestamp + 20 days);
        
        // Another user stakes
        address user2 = makeAddr("User2");
        _mintAndApprove(user2, 1000e18);
        vm.prank(user2);
        staking.stake(tokenA, 100e18);
        uint256 secondStakeTime = block.timestamp;
        
        // Verify lastMinted was advanced again
        assertEq(staking.lastMinted(), secondStakeTime, "lastMinted should advance to current time");
        
        // Trigger accrual after 1 hour
        vm.warp(block.timestamp + 1 hours);
        
        vm.prank(gauge);
        uint256 reward = staking.accrueReward(tokenA);
        
        // Should only get rewards for 1 hour, not the 30 days of empty time
        uint256 expectedReward = 1 hours * rate;
        assertEq(reward, expectedReward, "Should only accrue rewards from second stake time");
    }

    /**
     * @notice Tests the exact attack scenario from the issue description
     * @dev Simulates: deployment -> time passes -> flash loan stake -> trigger accrual -> unstake
     */
    function test_FlashLoanAttackScenarioPrevented() public {
        // Step 1: Contract is deployed (done in setUp)
        uint256 deploymentTime = staking.lastMinted();
        
        // Step 2: Significant time passes (e.g., 90 days)
        uint256 emptyPeriod = 90 days;
        vm.warp(block.timestamp + emptyPeriod);
        
        // Step 3: Attacker gets flash loan and stakes
        address attacker = makeAddr("Attacker");
        uint256 flashLoanAmount = 1000e18;
        _mintAndApprove(attacker, flashLoanAmount);
        
        vm.startPrank(attacker);
        staking.stake(tokenA, flashLoanAmount);
        
        // Step 4: Attacker triggers accrueReward (simulating a swap)
        vm.stopPrank();
        vm.prank(gauge);
        uint256 attackerReward = staking.accrueReward(tokenA);
        
        // Step 5: Verify attacker didn't get banked rewards
        uint256 bankedReward = emptyPeriod * rate;
        
        // With the fix, attacker gets 0 reward because no time has passed since their stake
        assertEq(attackerReward, 0, "Attacker should get 0 reward in same block");
        assertLt(attackerReward, bankedReward / 100, "Attacker should not get significant portion of banked rewards");
        
        // Step 6: Even after waiting a bit, should only get proportional reward
        vm.warp(block.timestamp + 1 days);
        vm.prank(gauge);
        uint256 laterReward = staking.accrueReward(tokenA);
        
        uint256 expectedLaterReward = 1 days * rate;
        assertEq(laterReward, expectedLaterReward, "Should only get 1 day of rewards");
        // Verify attacker doesn't get majority of banked rewards (90 days >> 1 day)
        uint256 attackProtectionThreshold = bankedReward / 10; // 9 days worth
        assertLt(laterReward, attackProtectionThreshold, "Should not get majority of 90 days banked rewards");
    }

    /**
     * @notice Verifies lastMinted advances even with zero elapsed time initially
     */
    function test_LastMintedAdvancesImmediatelyOnFirstStake() public {
        uint256 deploymentTime = staking.lastMinted();
        
        // Stake immediately after deployment (no time warp)
        vm.prank(user);
        staking.stake(tokenA, 100e18);
        
        // lastMinted should still be current time
        assertEq(staking.lastMinted(), block.timestamp, "lastMinted should be current time even with no elapsed time");
    }
}
