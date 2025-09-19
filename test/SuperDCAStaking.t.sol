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
