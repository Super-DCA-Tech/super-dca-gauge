// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SuperDCAHook} from "../src/SuperDCAHook.sol";
import {SuperDCAToken} from "../src/SuperDCAToken.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {MockERC20Token} from "./mocks/MockERC20Token.sol";

contract SuperDCAHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    SuperDCAHook hook;
    SuperDCAToken dcaToken;
    PoolId poolId;
    address developer = address(0xDEADBEEF);
    uint256 mintRate = 100; // SDCA tokens per second
    MockERC20Token public weth;

    function setUp() public {
        // Deploy mock WETH
        weth = new MockERC20Token("Wrapped Ether", "WETH", 18);
        
        // Deploy core Uniswap V4 contracts
        deployFreshManagerAndRouters();
        
        // Deploy the DCA token implementation
        SuperDCAToken tokenImplementation = new SuperDCAToken();

        // Deploy proxy and initialize it
        bytes memory initData = abi.encodeCall(
            SuperDCAToken.initialize,
            (
                address(this), // defaultAdmin
                address(this), // pauser
                address(this), // minter
                address(this) // upgrader
            )
        );

        dcaToken = SuperDCAToken(
            address(new TransparentUpgradeableProxy(address(tokenImplementation), address(this), initData))
        );

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG) ^ (0x4242 << 144)
        );
        bytes memory constructorArgs = abi.encode(manager, dcaToken, developer, mintRate);
        deployCodeTo("SuperDCAHook.sol:SuperDCAHook", constructorArgs, flags);
        hook = SuperDCAHook(flags);

        // Grant minter role to the hook
        bytes32 MINTER_ROLE = keccak256("MINTER_ROLE");
        dcaToken.grantRole(MINTER_ROLE, address(hook));

        // Mint tokens for testing
        weth.mint(address(this), 1000e18);
        dcaToken.mint(address(this), 1000e18);

        // Create the pool using tokens in ascending order
        if (address(weth) < address(dcaToken)) {
            key = PoolKey({
                currency0: Currency.wrap(address(weth)),
                currency1: Currency.wrap(address(dcaToken)),
                fee: 500,
                tickSpacing: 60,
                hooks: IHooks(hook)
            });
        } else {
            key = PoolKey({
                currency0: Currency.wrap(address(dcaToken)),
                currency1: Currency.wrap(address(weth)),
                fee: 500,
                tickSpacing: 60,
                hooks: IHooks(hook)
            });
        }

        // Initialize the pool
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        
        // Approve tokens for liquidity addition
        weth.approve(address(modifyLiquidityRouter), type(uint256).max);
        dcaToken.approve(address(modifyLiquidityRouter), type(uint256).max);
    }

    function test_distribution_on_addLiquidity() public {
        // Setup: Stake some tokens first
        uint256 stakeAmount = 100e18;
        dcaToken.approve(address(hook), stakeAmount);
        hook.stake(address(weth), stakeAmount);

        // Add initial liquidity first
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: 1e18,
            salt: bytes32(0)
        });

        // Add the initial liquidity
        modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);

        uint256 startTime = hook.lastMinted();
        uint256 elapsed = 20;
        vm.warp(startTime + elapsed);

        // Add more liquidity which should trigger fee collection
        modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);

        // Calculate expected distribution
        uint256 mintAmount = elapsed * mintRate; // 20 * 100 = 2000
        uint256 communityShare = mintAmount / 2; // 1000
        uint256 developerShare = mintAmount / 2; // 1000

        // Add the 1 wei to community share if mintAmount is odd
        if (mintAmount % 2 == 1) {
            communityShare += 1;
        }

        // Verify distributions
        assertEq(dcaToken.balanceOf(developer), developerShare, "Developer should receive correct share");
        assertEq(hook.lastMinted(), startTime + elapsed, "Last minted timestamp should be updated");

        // Verify the donation by checking that there are fees for the pool
        // Note: Can't figure out how to check the donation fees got to the pool
        // so I will verify this on the testnet work.
        // TODO: Verify this on testnet work.
    }

    function test_distribution_on_removeLiquidity() public {
        // Setup: Stake some tokens first
        uint256 stakeAmount = 100e18;
        dcaToken.approve(address(hook), stakeAmount);
        hook.stake(address(weth), stakeAmount);

        // First add liquidity using explicit parameters
        IPoolManager.ModifyLiquidityParams memory addParams = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: 1e18,
            salt: bytes32(0)
        });
        modifyLiquidityRouter.modifyLiquidity(key, addParams, ZERO_BYTES);

        uint256 startTime = hook.lastMinted();
        uint256 elapsed = 20;
        vm.warp(startTime + elapsed);

        // Remove liquidity using explicit parameters
        IPoolManager.ModifyLiquidityParams memory removeParams = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: -1,
            salt: bytes32(0)
        });
        modifyLiquidityRouter.modifyLiquidity(key, removeParams, ZERO_BYTES);

        // Calculate expected distribution using the same logic as addLiquidity:
        // They are split evenly unless the mintAmount is odd, in which case the community gets 1 extra wei.
        uint256 mintAmount = elapsed * mintRate; // 20 * 100 = 2000
        uint256 developerShare = mintAmount / 2; // Equal split (rounded down)
        uint256 communityShare = mintAmount / 2; // Equal split (rounded down)
        if (mintAmount % 2 == 1) {
            communityShare += 1;
        }

        // Verify distributions:
        // Developer should receive their share while the pool (via manager) gets the community share.
        assertEq(dcaToken.balanceOf(developer), developerShare, "Developer should receive correct share");
        assertEq(hook.lastMinted(), startTime + elapsed, "Last minted timestamp should be updated");

        // Verify the donation by checking that there are fees for the pool
        // Note: Can't figure out how to check the donation fees got to the pool
        // so I will verify this on the testnet work.
        // TODO: Verify this on testnet work.
    }

    function test_initialization() public {
        // Test initial state
        assertEq(address(hook.superDCAToken()), address(dcaToken), "DCA token not set correctly");
        assertEq(hook.developerAddress(), developer, "Developer address not set correctly");
        assertEq(hook.mintRate(), mintRate, "Mint rate not set correctly");
        assertEq(hook.lastMinted(), block.timestamp, "Last minted time not set correctly");
        assertEq(hook.totalStakedAmount(), 0, "Initial staked amount should be 0");
        assertEq(hook.rewardIndex(), 1e18, "Initial reward index should be 1e18");

        // Test hook permissions
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeAddLiquidity, "beforeAddLiquidity should be enabled");
        assertTrue(permissions.beforeRemoveLiquidity, "beforeRemoveLiquidity should be enabled");
        assertFalse(permissions.afterAddLiquidity, "afterAddLiquidity should be disabled");
        assertFalse(permissions.afterRemoveLiquidity, "afterRemoveLiquidity should be disabled");
        assertFalse(permissions.beforeSwap, "beforeSwap should be disabled");
        assertFalse(permissions.afterSwap, "afterSwap should be disabled");
        assertFalse(permissions.beforeDonate, "beforeDonate should be disabled");
        assertFalse(permissions.afterDonate, "afterDonate should be disabled");
        assertFalse(permissions.beforeSwapReturnDelta, "beforeSwapReturnDelta should be disabled");
        assertFalse(permissions.afterSwapReturnDelta, "afterSwapReturnDelta should be disabled");
        assertFalse(permissions.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta should be disabled");
        assertFalse(permissions.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta should be disabled");
    }

    function test_stake() public {
        // Setup: Approve tokens for staking
        uint256 stakeAmount = 100e18;
        dcaToken.approve(address(hook), stakeAmount);
        
        // Record initial state
        uint256 initialBalance = dcaToken.balanceOf(address(this));
        uint256 initialStakedAmount = hook.totalStakedAmount();
        uint256 initialRewardIndex = hook.rewardIndex();
        
        // Perform stake
        hook.stake(address(weth), stakeAmount);
        
        // Verify token transfer
        assertEq(
            dcaToken.balanceOf(address(this)), 
            initialBalance - stakeAmount, 
            "Tokens should be transferred from user"
        );
        assertEq(
            dcaToken.balanceOf(address(hook)), 
            stakeAmount, 
            "Hook should receive tokens"
        );
        
        // Verify staking state updates
        assertEq(hook.totalStakedAmount(), initialStakedAmount + stakeAmount, "Total staked amount should increase");
        assertEq(hook.getUserStakeAmount(address(this), address(weth)), stakeAmount, "User stake amount should be recorded");
        
        // Verify token is in user's staked tokens list
        address[] memory stakedTokens = hook.getUserStakedTokens(address(this));
        assertEq(stakedTokens.length, 1, "User should have one staked token");
        assertEq(stakedTokens[0], address(weth), "Staked token should be WETH");
        
        // Verify reward info updates
        (uint256 stakedAmount, uint256 lastRewardIndex) = hook.tokenRewardInfos(address(weth));
        assertEq(stakedAmount, stakeAmount, "Token reward info staked amount should be updated");
        assertEq(lastRewardIndex, initialRewardIndex, "Token reward info last reward index should be updated");
    }

    function test_stake_revert_zeroAmount() public {
        vm.expectRevert(SuperDCAHook.ZeroAmount.selector);
        hook.stake(address(weth), 0);
    }

    function test_unstake() public {
        // Setup: Stake tokens first
        uint256 stakeAmount = 100e18;
        dcaToken.approve(address(hook), stakeAmount);
        hook.stake(address(weth), stakeAmount);
        
        // Record state before unstake
        uint256 initialBalance = dcaToken.balanceOf(address(this));
        uint256 initialStakedAmount = hook.totalStakedAmount();
        
        // Perform unstake
        hook.unstake(address(weth), stakeAmount);
        
        // Verify token transfer
        assertEq(
            dcaToken.balanceOf(address(this)), 
            initialBalance + stakeAmount, 
            "Tokens should be returned to user"
        );
        assertEq(
            dcaToken.balanceOf(address(hook)), 
            0, 
            "Hook should have no tokens"
        );
        
        // Verify staking state updates
        assertEq(hook.totalStakedAmount(), initialStakedAmount - stakeAmount, "Total staked amount should decrease");
        assertEq(hook.getUserStakeAmount(address(this), address(weth)), 0, "User stake amount should be zero");
        
        // Verify token is removed from user's staked tokens list
        address[] memory stakedTokens = hook.getUserStakedTokens(address(this));
        assertEq(stakedTokens.length, 0, "User should have no staked tokens");
    }

    function test_unstake_revert_insufficientBalance() public {
        // Setup: Stake a smaller amount
        uint256 stakeAmount = 100e18;
        dcaToken.approve(address(hook), stakeAmount);
        hook.stake(address(weth), stakeAmount);

        // Try to unstake more than staked
        vm.expectRevert(SuperDCAHook.InsufficientBalance.selector);
        hook.unstake(address(weth), stakeAmount + 1);

        // Try to unstake from token that hasn't been staked
        vm.expectRevert(SuperDCAHook.InsufficientBalance.selector);
        hook.unstake(address(dcaToken), stakeAmount);
    }

    function test_reward_calculation() public {
        // Setup: Stake tokens
        uint256 stakeAmount = 100e18;
        dcaToken.approve(address(hook), stakeAmount);
        hook.stake(address(weth), stakeAmount);

        // Add liquidity to enable rewards
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: 1e18,
            salt: bytes32(0)
        });
        modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);

        // Record initial state
        uint256 startTime = hook.lastMinted();
        uint256 initialDevBalance = dcaToken.balanceOf(developer);

        // Advance time
        uint256 elapsed = 20;
        vm.warp(startTime + elapsed);

        // Trigger reward distribution
        modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);

        // Calculate expected rewards
        uint256 expectedMintAmount = elapsed * mintRate; // 20 * 100 = 2000
        uint256 expectedDevShare = expectedMintAmount / 2; // 1000

        // Verify rewards
        assertEq(
            dcaToken.balanceOf(developer) - initialDevBalance,
            expectedDevShare,
            "Developer should receive correct reward amount"
        );
        assertEq(hook.lastMinted(), startTime + elapsed, "Last minted time should be updated");
    }

    function test_reward_distribution_no_liquidity() public {
        // Setup: Stake tokens
        uint256 stakeAmount = 100e18;
        dcaToken.approve(address(hook), stakeAmount);
        hook.stake(address(weth), stakeAmount);

        // Record initial state
        uint256 startTime = hook.lastMinted();
        uint256 initialDevBalance = dcaToken.balanceOf(developer);

        // Advance time
        uint256 elapsed = 20;
        vm.warp(startTime + elapsed);

        // Trigger reward distribution without adding liquidity
        modifyLiquidityRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: 1e18, // No liquidity change
            salt: bytes32(0)
        }), ZERO_BYTES);

        // Remove liquidity
        modifyLiquidityRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: -1e18,
            salt: bytes32(0)
        }), ZERO_BYTES);

        // The developer should receive all the rewards since there is no liquidity
        uint256 expectedDevShare = elapsed * mintRate; // 20 * 100 = 2000

        // Verify rewards
        assertEq(
            dcaToken.balanceOf(developer) - initialDevBalance,
            expectedDevShare,
            "Developer should receive correct reward amount"
        );
        assertEq(hook.lastMinted(), startTime + elapsed, "Last minted time should be updated");
    }

    function test_getPendingRewards() public {
        // Setup: Stake tokens
        uint256 stakeAmount = 100e18;
        dcaToken.approve(address(hook), stakeAmount);
        hook.stake(address(weth), stakeAmount);

        // Record initial state
        uint256 startTime = hook.lastMinted();

        // Advance time
        uint256 elapsed = 20;
        vm.warp(startTime + elapsed);

        // Calculate expected pending rewards
        uint256 expectedRewards = elapsed * mintRate; // 20 * 100 = 2000

        // Check pending rewards
        assertEq(
            hook.getPendingRewards(address(weth)),
            expectedRewards,
            "Pending rewards calculation incorrect"
        );
    }

    // --------------------------------------------
    // Additional tests to increase coverage for SuperDCAHook.sol
    // --------------------------------------------

    // Test that if no time has passed, distribution yields no rewards.
    function test_noRewardDistributionWhenNoTimeElapsed() public {
        uint256 stakeAmount = 100e18;
        dcaToken.approve(address(hook), stakeAmount);
        hook.stake(address(weth), stakeAmount);

        uint256 initialDevBal = dcaToken.balanceOf(developer);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: 1e18,
            salt: bytes32(0)
        });

        // Without warping time, elapsed==0 so no rewards will be minted
        modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);

        assertEq(
            dcaToken.balanceOf(developer),
            initialDevBal,
            "No rewards should be distributed with zero elapsed time"
        );
    }

    // Test that no rewards are minted when the pool key fee is not 500.
    function test_mintTokensWrongFee() public {
        // Construct a pool key with fee != 500 (use fee 600)
        PoolKey memory wrongFeeKey;
        if (address(weth) < address(dcaToken)) {
            wrongFeeKey = PoolKey({
                currency0: Currency.wrap(address(weth)),
                currency1: Currency.wrap(address(dcaToken)),
                fee: 600,
                tickSpacing: 60,
                hooks: IHooks(hook)
            });
        } else {
            wrongFeeKey = PoolKey({
                currency0: Currency.wrap(address(dcaToken)),
                currency1: Currency.wrap(address(weth)),
                fee: 600,
                tickSpacing: 60,
                hooks: IHooks(hook)
            });
        }

        manager.initialize(wrongFeeKey, SQRT_PRICE_1_1);

        // Stake tokens for the non-SuperDCAToken in the pool key
        uint256 stakeAmount = 100e18;
        dcaToken.approve(address(hook), stakeAmount);
        // Determine the "other" token so that tokenRewardInfo is nonzero
        address otherToken = (address(dcaToken) == Currency.unwrap(wrongFeeKey.currency0))
            ? Currency.unwrap(wrongFeeKey.currency1)
            : Currency.unwrap(wrongFeeKey.currency0);
        hook.stake(otherToken, stakeAmount);

        uint256 initialDevBal = dcaToken.balanceOf(developer);
        uint256 elapsed = 20;
        vm.warp(block.timestamp + elapsed);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: 1e18,
            salt: bytes32(0)
        });

        modifyLiquidityRouter.modifyLiquidity(wrongFeeKey, params, ZERO_BYTES);
        // Because the fee is not 500, no reward tokens are minted.
        assertEq(
            dcaToken.balanceOf(developer),
            initialDevBal,
            "No rewards should be distributed for wrong fee"
        );
    }

    // Test that no rewards are minted when the pool key does not include SuperDCAToken.
    function test_mintTokensWrongToken() public {
        // Deploy a dummy token that is not the SuperDCAToken.
        MockERC20Token dummy = new MockERC20Token("Dummy Token", "DUMMY", 18);
        
        // Mint tokens for liquidity
        dummy.mint(address(this), 1000e18);
        weth.mint(address(this), 1000e18);
        
        // Approve tokens
        dummy.approve(address(modifyLiquidityRouter), type(uint256).max);
        weth.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Construct pool key with tokens in correct order
        PoolKey memory wrongTokenKey;
        if (address(dummy) < address(weth)) {
            wrongTokenKey = PoolKey({
                currency0: Currency.wrap(address(dummy)),
                currency1: Currency.wrap(address(weth)),
                fee: 500,
                tickSpacing: 60,
                hooks: IHooks(hook)
            });
        } else {
            wrongTokenKey = PoolKey({
                currency0: Currency.wrap(address(weth)),
                currency1: Currency.wrap(address(dummy)),
                fee: 500,
                tickSpacing: 60,
                hooks: IHooks(hook)
            });
        }

        manager.initialize(wrongTokenKey, SQRT_PRICE_1_1);

        uint256 initialDevBal = dcaToken.balanceOf(developer);
        uint256 elapsed = 20;
        vm.warp(block.timestamp + elapsed);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: 1e18,
            salt: bytes32(0)
        });

        modifyLiquidityRouter.modifyLiquidity(wrongTokenKey, params, ZERO_BYTES);
        
        assertEq(
            dcaToken.balanceOf(developer),
            initialDevBal,
            "No rewards should be distributed for pool without SuperDCAToken"
        );
    }

    // Test that getPendingRewards returns zero when no stake exists.
    function test_getPendingRewards_noStake() public {
        assertEq(
            hook.getPendingRewards(address(weth)),
            0,
            "Pending rewards should be 0 when no stake exists"
        );
    }

    // Test that getPendingRewards returns zero if no time has elapsed even after staking.
    function test_getPendingRewards_noTimeElapsed() public {
        uint256 stakeAmount = 100e18;
        dcaToken.approve(address(hook), stakeAmount);
        hook.stake(address(weth), stakeAmount);
        
        // Immediately check pending rewards; should be 0 because block.timestamp did not advance.
        assertEq(
            hook.getPendingRewards(address(weth)),
            0,
            "Pending rewards should be 0 with no elapsed time"
        );
    }

    // Test donation branch when SuperDCAToken is currency0.
    function test_donation_branch_currency0() public {
        // Create a new mock token with higher address than dcaToken
        MockERC20Token newToken = new MockERC20Token{salt: bytes32(uint256(1))}("New Token", "NEW", 18);
        require(address(dcaToken) < address(newToken), "Token addresses in wrong order");

        // Create a custom pool key with currency0 = dcaToken and currency1 = newToken
        PoolKey memory customKey = PoolKey({
            currency0: Currency.wrap(address(dcaToken)),
            currency1: Currency.wrap(address(newToken)),
            fee: 500,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        
        // Initialize pool
        manager.initialize(customKey, SQRT_PRICE_1_1);

        // Mint tokens for liquidity
        newToken.mint(address(this), 1000e18);
        newToken.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Stake tokens
        uint256 stakeAmount = 100e18;
        dcaToken.approve(address(hook), stakeAmount);
        hook.stake(address(newToken), stakeAmount);

        // Add initial liquidity
        IPoolManager.ModifyLiquidityParams memory addParams = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: 1e18,
            salt: bytes32(0)
        });
        modifyLiquidityRouter.modifyLiquidity(customKey, addParams, ZERO_BYTES);

        uint256 startTime = hook.lastMinted();
        uint256 elapsed = 20;
        vm.warp(startTime + elapsed);

        uint256 initialDevBal = dcaToken.balanceOf(developer);
        uint256 initialPoolBal = dcaToken.balanceOf(address(manager));

        modifyLiquidityRouter.modifyLiquidity(customKey, addParams, ZERO_BYTES);

        uint256 mintAmount = elapsed * mintRate;
        uint256 expectedDevShare = mintAmount / 2;
        uint256 expectedCommunityShare = mintAmount - expectedDevShare;

        assertEq(
            dcaToken.balanceOf(developer) - initialDevBal,
            expectedDevShare,
            "Developer should receive correct share in currency0 branch"
        );
        assertEq(
            dcaToken.balanceOf(address(manager)) - initialPoolBal,
            expectedCommunityShare,
            "PoolManager should receive community share in currency0 branch"
        );
        assertEq(
            dcaToken.balanceOf(address(hook)),
            0,
            "Hook balance should be zero after distribution"
        );
    }

    // Test donation branch when SuperDCAToken is currency1.
    function test_donation_branch_currency1() public {
        // Create a new mock token with lower address than dcaToken
        MockERC20Token newToken = new MockERC20Token{salt: bytes32(uint256(2))}("New Token", "NEW", 18);
        require(address(newToken) < address(dcaToken), "Token addresses in wrong order");

        // Create a custom pool key ensuring currency0 has lower address
        PoolKey memory customKey = PoolKey({
            currency0: Currency.wrap(address(newToken)),
            currency1: Currency.wrap(address(dcaToken)),
            fee: 500,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        // Initialize pool
        manager.initialize(customKey, SQRT_PRICE_1_1);

        // Mint tokens for liquidity
        newToken.mint(address(this), 1000e18);
        newToken.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Stake tokens
        uint256 stakeAmount = 100e18;
        dcaToken.approve(address(hook), stakeAmount);
        hook.stake(address(newToken), stakeAmount);

        // Add initial liquidity
        IPoolManager.ModifyLiquidityParams memory addParams = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: 1e18,
            salt: bytes32(0)
        });
        modifyLiquidityRouter.modifyLiquidity(customKey, addParams, ZERO_BYTES);

        uint256 startTime = hook.lastMinted();
        uint256 elapsed = 20;
        vm.warp(startTime + elapsed);

        uint256 initialDevBal = dcaToken.balanceOf(developer);
        uint256 initialPoolBal = dcaToken.balanceOf(address(manager));

        modifyLiquidityRouter.modifyLiquidity(customKey, addParams, ZERO_BYTES);

        uint256 mintAmount = elapsed * mintRate;
        uint256 expectedDevShare = mintAmount / 2;
        uint256 expectedCommunityShare = mintAmount - expectedDevShare;

        assertEq(
            dcaToken.balanceOf(developer) - initialDevBal,
            expectedDevShare,
            "Developer should receive correct share in currency1 branch"
        );
        assertEq(
            dcaToken.balanceOf(address(manager)) - initialPoolBal,
            expectedCommunityShare,
            "PoolManager should receive community share in currency1 branch"
        );
        assertEq(
            dcaToken.balanceOf(address(hook)),
            0,
            "Hook balance should be zero after distribution"
        );
    }
}
