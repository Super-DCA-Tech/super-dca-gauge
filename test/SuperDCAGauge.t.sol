// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SuperDCAGauge} from "../src/SuperDCAGauge.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC20Token} from "./mocks/MockERC20Token.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";



contract SuperDCAGaugeTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;

    SuperDCAGauge hook;
    MockERC20Token public dcaToken;
    PoolId poolId;
    address developer = address(0xDEADBEEF);
    uint256 mintRate = 100; // SDCA tokens per second
    MockERC20Token public weth;

    // --------------------------------------------
    // Helper Functions
    // --------------------------------------------

    // Creates a pool key with the tokens ordered by address.
    function _createPoolKey(address tokenA, address tokenB, uint24 fee) internal view returns (PoolKey memory key) {
        return tokenA < tokenB
            ? PoolKey({
                currency0: Currency.wrap(tokenA),
                currency1: Currency.wrap(tokenB),
                fee: fee,
                tickSpacing: 60, // hardcoded tick spacing used everywhere
                hooks: IHooks(hook)
            })
            : PoolKey({
                currency0: Currency.wrap(tokenB),
                currency1: Currency.wrap(tokenA),
                fee: fee,
                tickSpacing: 60,
                hooks: IHooks(hook)
            });
    }

    // Constructs liquidity parameters so you don't have to re-write them.
    function _getLiquidityParams(int128 liquidityDelta)
        internal
        pure
        returns (IPoolManager.ModifyLiquidityParams memory)
    {
        return IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: liquidityDelta,
            salt: bytes32(0)
        });
    }

    // Helper to modify liquidity with constructed liquidity parameters.
    function _modifyLiquidity(PoolKey memory _key, int128 liquidityDelta) internal {
        IPoolManager.ModifyLiquidityParams memory params = _getLiquidityParams(liquidityDelta);
        modifyLiquidityRouter.modifyLiquidity(_key, params, ZERO_BYTES);
    }

    // Helper to perform a stake (includes approval).
    function _stake(address stakingToken, uint256 amount) internal {
        dcaToken.approve(address(hook), amount);
        hook.stake(stakingToken, amount);
    }

    // (Optional) Helper to perform an unstake.
    function _unstake(address stakingToken, uint256 amount) internal {
        hook.unstake(stakingToken, amount);
    }

    function setUp() public virtual {
        // Deploy mock WETH
        weth = new MockERC20Token("Wrapped Ether", "WETH", 18);

        // Deploy mock DCA token instead of the actual implementation
        dcaToken = new MockERC20Token("Super DCA Token", "SDCA", 18);

        // Deploy core Uniswap V4 contracts
        deployFreshManagerAndRouters();
        // TODO: REF
        Deployers.deployMintAndApprove2Currencies(); // currency0 = weth, currency1 = dcaToken

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG
            ) ^ (0x4242 << 144)
        );
       
        address impl = address(new SuperDCAGauge());

        bytes memory initData = abi.encodeCall(
            SuperDCAGauge.initialize,
            (manager, address(dcaToken), developer, mintRate)
        );


        deployCodeTo(
            "ERC1967Proxy.sol:ERC1967Proxy",
            abi.encode(impl, initData),
            flags
        );

        hook = SuperDCAGauge(flags);

        // No need to grant minter role as we'll use the mock's mint function directly

        // Mint tokens for testing
        weth.mint(address(this), 1000e18);
        dcaToken.mint(address(this), 1000e18);

        // Create the pool key using the helper (fee always set to 500 here)
        key = _createPoolKey(address(weth), address(dcaToken), LPFeeLibrary.DYNAMIC_FEE_FLAG);

        // Initialize the pool
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Approve tokens for liquidity addition
        weth.approve(address(modifyLiquidityRouter), type(uint256).max);
        dcaToken.approve(address(modifyLiquidityRouter), type(uint256).max);
    }
}

contract ConstructorTest is SuperDCAGaugeTest {
    function test_initialization() public view {
        // Test initial state
        assertEq(address(hook.superDCAToken()), address(dcaToken), "DCA token not set correctly");
        assertEq(hook.developerAddress(), developer, "Developer address not set correctly");
        assertEq(hook.mintRate(), mintRate, "Mint rate not set correctly");
        assertEq(hook.lastMinted(), block.timestamp, "Last minted time not set correctly");
        assertEq(hook.totalStakedAmount(), 0, "Initial staked amount should be 0");
        assertEq(hook.rewardIndex(), 0, "Initial reward index should be 1e18");

        // Test hook permissions
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeInitialize, "beforeInitialize should be enabled");
        assertTrue(permissions.beforeAddLiquidity, "beforeAddLiquidity should be enabled");
        assertTrue(permissions.beforeRemoveLiquidity, "beforeRemoveLiquidity should be enabled");
        assertFalse(permissions.afterAddLiquidity, "afterAddLiquidity should be disabled");
        assertFalse(permissions.afterRemoveLiquidity, "afterRemoveLiquidity should be disabled");
        assertTrue(permissions.beforeSwap, "beforeSwap should be disabled");
        assertFalse(permissions.afterSwap, "afterSwap should be disabled");
        assertFalse(permissions.beforeDonate, "beforeDonate should be disabled");
        assertFalse(permissions.afterDonate, "afterDonate should be disabled");
        assertFalse(permissions.beforeSwapReturnDelta, "beforeSwapReturnDelta should be disabled");
        assertFalse(permissions.afterSwapReturnDelta, "afterSwapReturnDelta should be disabled");
        assertFalse(permissions.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta should be disabled");
        assertFalse(permissions.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta should be disabled");
        assertTrue(permissions.afterInitialize, "afterInitialize should be enabled");
    }
}

contract BeforeInitializeTest is SuperDCAGaugeTest {
    function test_beforeInitialize() public {
        // Create a pool key with dynamic fee flag and SuperDCAToken
        PoolKey memory correctKey = _createPoolKey(address(0xBEEF), address(dcaToken), LPFeeLibrary.DYNAMIC_FEE_FLAG);
        manager.initialize(correctKey, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_revert_wrongToken() public {
        // Create a pool key with two tokens that aren't SuperDCAToken
        PoolKey memory wrongTokenKey = _createPoolKey(address(weth), address(0xBEEF), LPFeeLibrary.DYNAMIC_FEE_FLAG);
        // TODO: Handle verify WrappedErrors
        vm.expectRevert();
        manager.initialize(wrongTokenKey, SQRT_PRICE_1_1);
    }
}

contract AfterInitializeTest is SuperDCAGaugeTest {
    function test_afterInitialize_SuccessWithDynamicFee() public {
        // Create a new key specifically for this test to avoid state conflicts
        MockERC20Token tokenOther = new MockERC20Token("Other", "OTH", 18);
        PoolKey memory dynamicKey =
            _createPoolKey(address(tokenOther), address(dcaToken), LPFeeLibrary.DYNAMIC_FEE_FLAG);

        // Expect no revert
        manager.initialize(dynamicKey, SQRT_PRICE_1_1);
    }

    function test_RevertWhen_InitializingWithStaticFee() public {
        // Create a new key specifically for this test
        MockERC20Token tokenOther = new MockERC20Token("Other", "OTH", 18);
        uint24 staticFee = 500;
        PoolKey memory staticKey = _createPoolKey(address(tokenOther), address(dcaToken), staticFee);

        // Expect revert from the afterInitialize hook
        vm.expectRevert();
        manager.initialize(staticKey, SQRT_PRICE_1_1);
    }
}

contract BeforeAddLiquidityTest is SuperDCAGaugeTest {
    function test_distribution_on_addLiquidity() public {
        // Setup: Stake some tokens first using helper.
        uint256 stakeAmount = 100e18;
        _stake(address(weth), stakeAmount);

        // Add initial liquidity first using the helper.
        _modifyLiquidity(key, 1e18);

        uint256 startTime = hook.lastMinted();
        uint256 elapsed = 20;
        vm.warp(startTime + elapsed);

        // Add more liquidity which should trigger fee collection.
        _modifyLiquidity(key, 1e18);

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

    function test_noRewardDistributionWhenNoTimeElapsed() public {
        uint256 stakeAmount = 100e18;
        _stake(address(weth), stakeAmount);

        uint256 initialDevBal = dcaToken.balanceOf(developer);
        _modifyLiquidity(key, 1e18);

        assertEq(
            dcaToken.balanceOf(developer), initialDevBal, "No rewards should be distributed with zero elapsed time"
        );
    }
}

contract BeforeRemoveLiquidityTest is SuperDCAGaugeTest {
    function test_distribution_on_removeLiquidity() public {
        // Setup: Stake some tokens first
        uint256 stakeAmount = 100e18;
        _stake(address(weth), stakeAmount);

        // First add liquidity using explicit parameters
        _modifyLiquidity(key, 1e18);

        uint256 startTime = hook.lastMinted();
        uint256 elapsed = 20;
        vm.warp(startTime + elapsed);

        // Remove liquidity using explicit parameters
        _modifyLiquidity(key, -1);

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
}

contract StakeTest is SuperDCAGaugeTest {
    function test_stake() public {
        // Setup: Approve and stake tokens using helper.
        uint256 stakeAmount = 100e18;

        // Record initial state BEFORE staking
        uint256 initialBalance = dcaToken.balanceOf(address(this));
        uint256 initialStakedAmount = hook.totalStakedAmount();
        uint256 initialRewardIndex = hook.rewardIndex();

        // Perform stake
        _stake(address(weth), stakeAmount);

        // Verify token transfer
        assertEq(
            dcaToken.balanceOf(address(this)), initialBalance - stakeAmount, "Tokens should be transferred from user"
        );
        assertEq(dcaToken.balanceOf(address(hook)), stakeAmount, "Hook should receive tokens");

        // Verify staking state updates
        assertEq(hook.totalStakedAmount(), initialStakedAmount + stakeAmount, "Total staked amount should increase");
        assertEq(
            hook.getUserStakeAmount(address(this), address(weth)), stakeAmount, "User stake amount should be recorded"
        );

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
        vm.expectRevert(SuperDCAGauge.ZeroAmount.selector);
        hook.stake(address(weth), 0);
    }

    function test_multiple_stakes_same_token() public {
        // First stake
        uint256 firstStake = 100e18;
        _stake(address(weth), firstStake);

        // Second stake
        uint256 secondStake = 50e18;
        _stake(address(weth), secondStake);

        // Verify combined stake amount
        assertEq(
            hook.getUserStakeAmount(address(this), address(weth)),
            firstStake + secondStake,
            "Combined stake amount incorrect"
        );

        // Verify total staked amount
        assertEq(hook.totalStakedAmount(), firstStake + secondStake, "Total staked amount incorrect");
    }
}

contract UnstakeTest is SuperDCAGaugeTest {
    function setUp() public override {
        super.setUp();
        // Stake initial amount in setup
        _stake(address(weth), 100e18);
    }

    function test_unstake() public {
        uint256 stakeAmount = 100e18;

        // Record state before unstake
        uint256 initialBalance = dcaToken.balanceOf(address(this));
        uint256 initialStakedAmount = hook.totalStakedAmount();

        // Perform unstake
        _unstake(address(weth), stakeAmount);

        // Verify token transfer
        assertEq(dcaToken.balanceOf(address(this)), initialBalance + stakeAmount, "Tokens should be returned to user");
        assertEq(dcaToken.balanceOf(address(hook)), 0, "Hook should have no tokens");

        // Verify staking state updates
        assertEq(hook.totalStakedAmount(), initialStakedAmount - stakeAmount, "Total staked amount should decrease");
        assertEq(hook.getUserStakeAmount(address(this), address(weth)), 0, "User stake amount should be zero");

        // Verify token is removed from user's staked tokens list
        address[] memory stakedTokens = hook.getUserStakedTokens(address(this));
        assertEq(stakedTokens.length, 0, "User should have no staked tokens");
    }

    function test_unstake_revert_insufficientBalance() public {
        // We already have 100e18 staked from setUp()
        // No need to stake again, just try to unstake more than we have
        vm.expectRevert(SuperDCAGauge.InsufficientBalance.selector);
        _unstake(address(weth), 101e18);

        // Try to unstake from token that hasn't been staked
        vm.expectRevert(SuperDCAGauge.InsufficientBalance.selector);
        _unstake(address(dcaToken), 100e18);
    }

    function test_partial_unstake() public {
        // Initial stake of 100e18 from setUp()
        uint256 initialStake = 100e18;
        uint256 partialUnstake = 60e18;

        // Record initial state
        uint256 initialBalance = dcaToken.balanceOf(address(this));

        // Perform partial unstake
        _unstake(address(weth), partialUnstake);

        // Verify remaining stake
        assertEq(
            hook.getUserStakeAmount(address(this), address(weth)),
            initialStake - partialUnstake,
            "Remaining stake incorrect"
        );

        // Verify token transfer
        assertEq(dcaToken.balanceOf(address(this)), initialBalance + partialUnstake, "Tokens not returned correctly");

        // Verify token still in staked list since we have remaining stake
        address[] memory stakedTokens = hook.getUserStakedTokens(address(this));
        assertEq(stakedTokens.length, 1, "Token should still be in staked list");
    }
}

contract GetUserStakedTokensTest is SuperDCAGaugeTest {
    function test_getUserStakedTokens() public {
        // Stake tokens
        _stake(address(weth), 100e18);
        _stake(address(address(0x01)), 100e18);

        // Get staked tokens
        address[] memory stakedTokens = hook.getUserStakedTokens(address(this));
        assertEq(stakedTokens.length, 2, "User should have two staked tokens");
        assertEq(stakedTokens[0], address(weth), "Staked token should be WETH");
        assertEq(stakedTokens[1], address(0x01), "Staked token should be 0x01");
    }
}

contract GetUserStakeAmountTest is SuperDCAGaugeTest {
    function test_getUserStakeAmount() public {
        // Stake tokens
        _stake(address(weth), 100e18);
        _stake(address(address(0x01)), 101e18);

        // Get stake amount
        uint256 stakeAmount = hook.getUserStakeAmount(address(this), address(weth));
        uint256 stakeAmount0x01 = hook.getUserStakeAmount(address(this), address(0x01));
        assertEq(stakeAmount, 100e18, "User should have 100e18 staked");
        assertEq(stakeAmount0x01, 101e18, "User should have 101e18 staked");
    }
}

contract RewardsTest is SuperDCAGaugeTest {
    MockERC20Token public usdc;
    PoolKey usdcKey;

    function setUp() public override {
        super.setUp();

        // Deploy mock USDC
        usdc = new MockERC20Token("USD Coin", "USDC", 6);
        usdc.mint(address(this), 1000e6);

        // Create USDC pool
        usdcKey = _createPoolKey(address(usdc), address(dcaToken), LPFeeLibrary.DYNAMIC_FEE_FLAG);
        manager.initialize(usdcKey, SQRT_PRICE_1_1);

        // Approve USDC for liquidity
        usdc.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Add initial stake for base tests
        _stake(address(weth), 100e18);
    }

    function test_reward_calculation() public {
        // Add liquidity to enable rewards
        _modifyLiquidity(key, 1e18);

        // Record initial state
        uint256 startTime = hook.lastMinted();
        uint256 initialDevBalance = dcaToken.balanceOf(developer);

        // Advance time
        uint256 elapsed = 20;
        vm.warp(startTime + elapsed);

        // Trigger reward distribution
        _modifyLiquidity(key, 1e18);

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
        _stake(address(weth), stakeAmount);

        // Record initial state
        uint256 startTime = hook.lastMinted();
        uint256 initialDevBalance = dcaToken.balanceOf(developer);

        // Advance time
        uint256 elapsed = 20;
        vm.warp(startTime + elapsed);

        // Trigger reward distribution without adding liquidity
        _modifyLiquidity(key, 1e18);

        // Remove liquidity
        _modifyLiquidity(key, -1e18);

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
        _stake(address(weth), stakeAmount);

        // Record initial state
        uint256 startTime = hook.lastMinted();

        // Advance time
        uint256 elapsed = 20;
        vm.warp(startTime + elapsed);

        // Calculate expected pending rewards
        uint256 expectedRewards = elapsed * mintRate; // 20 * 100 = 2000

        // Check pending rewards
        assertEq(hook.getPendingRewards(address(weth)), expectedRewards, "Pending rewards calculation incorrect");
    }

    function test_getPendingRewards_noStake() public {
        // Unstake the amount from setUp first
        _unstake(address(weth), 100e18);
        assertEq(hook.getPendingRewards(address(weth)), 0);
    }

    function test_getPendingRewards_noTimeElapsed() public view {
        assertEq(hook.getPendingRewards(address(weth)), 0);
    }

    function test_multiple_pool_rewards() public {
        // Mint more USDC for this test
        usdc.mint(address(this), 300e18);
        _stake(address(usdc), 300e18); // 75% of the total stake

        // Add liquidity to both pools
        _modifyLiquidity(key, 1e18);
        _modifyLiquidity(usdcKey, 1e18);

        // Record initial state
        uint256 startTime = hook.lastMinted();
        uint256 initialDevBalance = dcaToken.balanceOf(developer);

        // Advance time
        uint256 elapsed = 20;
        vm.warp(startTime + elapsed);

        // Trigger reward distribution by modifying liquidity
        _modifyLiquidity(key, 1e18);

        // Calculate expected rewards, ETH expects 1/4 of the total mint amount
        uint256 totalMintAmount = elapsed * mintRate; // 20 * 100 = 2000
        uint256 expectedDevShare = totalMintAmount / 2 / 4; // 1000 / 4 = 250

        // Verify developer rewards
        assertEq(
            dcaToken.balanceOf(developer) - initialDevBalance,
            expectedDevShare,
            "Developer should receive correct reward amount"
        );

        // Trigger reward distribution by modifying liquidity
        _modifyLiquidity(usdcKey, 1e18);

        // Verify developer rewards
        assertEq(
            dcaToken.balanceOf(developer) - initialDevBalance,
            totalMintAmount / 2, // Now receives all of the 1000 reward units
            "Developer should receive correct reward amount"
        );

        // Verify staking amounts
        assertEq(hook.getUserStakeAmount(address(this), address(weth)), 100e18, "WETH stake amount incorrect");
        assertEq(hook.getUserStakeAmount(address(this), address(usdc)), 300e18, "USDC stake amount incorrect");

        // Verify total staked amount
        assertEq(hook.totalStakedAmount(), 400e18, "Total staked amount incorrect");
    }

    function test_reward_distribution_multiple_users() public {
        // Setup second user
        address user2 = address(0xBEEF);
        deal(address(dcaToken), user2, 100e18);

        // First user already has 100e18 staked from setUp()

        // Stake as user2
        vm.startPrank(user2);
        dcaToken.approve(address(hook), 100e18);
        hook.stake(address(weth), 100e18);
        vm.stopPrank();

        // Add liquidity
        _modifyLiquidity(key, 1e18);

        // Advance time
        uint256 elapsed = 20;
        vm.warp(block.timestamp + elapsed);

        // Trigger reward distribution
        _modifyLiquidity(key, 1e18);

        // Calculate expected rewards
        uint256 totalMintAmount = elapsed * mintRate;
        uint256 expectedDevShare = totalMintAmount / 2;

        // Verify developer rewards
        assertEq(dcaToken.balanceOf(developer), expectedDevShare, "Developer reward incorrect");

        // TODO: Verify pool received its share
    }

    function test_reward_distribution_zero_total_stake() public {
        // Unstake everything
        _unstake(address(weth), 100e18);

        // Record initial state
        uint256 initialDevBalance = dcaToken.balanceOf(developer);

        // Advance time
        vm.warp(block.timestamp + 20);

        // Trigger reward distribution
        _modifyLiquidity(key, 1e18);

        // Verify no rewards were distributed
        assertEq(dcaToken.balanceOf(developer), initialDevBalance, "No rewards should be distributed with zero stake");
    }
}

contract AccessControlTest is SuperDCAGaugeTest {
    address managerUser;
    address nonManagerUser = makeAddr("nonManagerUser");
    address newManagerUser = makeAddr("newManagerUser");

    bytes4 internal constant ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR =
        bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)"));

    function setUp() public override {
        super.setUp();
        managerUser = developer;
        vm.assume(!hook.hasRole(hook.MANAGER_ROLE(), nonManagerUser));
        vm.assume(!hook.hasRole(hook.DEFAULT_ADMIN_ROLE(), nonManagerUser));
        vm.assume(!hook.hasRole(hook.MANAGER_ROLE(), newManagerUser));
    }

    function test_Should_AllowManagerToSetMintRate() public {
        uint256 newMintRate = 200;

        vm.prank(managerUser);
        hook.setMintRate(newMintRate);

        assertEq(hook.mintRate(), newMintRate, "Mint rate should be updated by manager");
    }

    function test_RevertWhen_NonManagerSetsMintRate() public {
        uint256 newMintRate = 200;

        vm.expectRevert(
            abi.encodeWithSelector(ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, nonManagerUser, hook.MANAGER_ROLE())
        );
        vm.prank(nonManagerUser);
        hook.setMintRate(newMintRate);
    }

    function test_Should_AllowAdminToUpdateManager() public {
        address currentAdmin = address(this);

        assertTrue(hook.hasRole(hook.MANAGER_ROLE(), managerUser), "Initial manager role incorrect");
        assertFalse(hook.hasRole(hook.MANAGER_ROLE(), newManagerUser), "New manager should not have role initially");

        vm.prank(currentAdmin);
        hook.updateManager(managerUser, newManagerUser);

        assertFalse(hook.hasRole(hook.MANAGER_ROLE(), managerUser), "Old manager should lose role");
        assertTrue(hook.hasRole(hook.MANAGER_ROLE(), newManagerUser), "New manager should gain role");
    }

    function test_RevertWhen_NonAdminUpdatesManager() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, nonManagerUser, hook.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(nonManagerUser);
        hook.updateManager(managerUser, newManagerUser);
    }
}

contract SetFeeTest is AccessControlTest {
    uint24 newInternalFee = 600;
    uint24 newExternalFee = 700;

    function test_Should_AllowManagerToSetInternalFee() public {
        uint24 initialExternalFee = hook.externalFee();
        uint24 initialInternalFee = hook.internalFee(); // Get the old fee

        vm.prank(managerUser);
        vm.expectEmit(true, true, true, true);
        emit SuperDCAGauge.FeeUpdated(true, initialInternalFee, newInternalFee); // Add old fee
        hook.setFee(true, newInternalFee);

        assertEq(hook.internalFee(), newInternalFee, "Internal fee should be updated");
        assertEq(hook.externalFee(), initialExternalFee, "External fee should remain unchanged");
    }

    function test_Should_AllowManagerToSetExternalFee() public {
        uint24 initialInternalFee = hook.internalFee();
        uint24 initialExternalFee = hook.externalFee(); // Get the old fee

        vm.prank(managerUser);
        vm.expectEmit(true, true, true, true);
        emit SuperDCAGauge.FeeUpdated(false, initialExternalFee, newExternalFee); // Add old fee
        hook.setFee(false, newExternalFee);

        assertEq(hook.externalFee(), newExternalFee, "External fee should be updated");
        assertEq(hook.internalFee(), initialInternalFee, "Internal fee should remain unchanged");
    }

    function test_RevertWhen_NonManagerSetsInternalFee() public {
        vm.expectRevert(
            abi.encodeWithSelector(ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, nonManagerUser, hook.MANAGER_ROLE())
        );
        vm.prank(nonManagerUser);
        hook.setFee(true, newInternalFee);
    }

    function test_RevertWhen_NonManagerSetsExternalFee() public {
        vm.expectRevert(
            abi.encodeWithSelector(ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, nonManagerUser, hook.MANAGER_ROLE())
        );
        vm.prank(nonManagerUser);
        hook.setFee(false, newExternalFee);
    }
}

contract SetInternalAddressTest is AccessControlTest {
    address internalUser = makeAddr("internalUser");

    function test_Should_AllowManagerToSetInternalAddressTrue() public {
        assertFalse(hook.isInternalAddress(internalUser), "User should not be internal initially");

        vm.prank(managerUser);
        vm.expectEmit(true, true, true, true);
        emit SuperDCAGauge.InternalAddressUpdated(internalUser, true);
        hook.setInternalAddress(internalUser, true);

        assertTrue(hook.isInternalAddress(internalUser), "User should be marked as internal");
    }

    function test_Should_AllowManagerToSetInternalAddressFalse() public {
        // First set to true
        vm.prank(managerUser);
        hook.setInternalAddress(internalUser, true);
        assertTrue(hook.isInternalAddress(internalUser), "User should be internal before setting false");

        // Now set to false
        vm.prank(managerUser);
        vm.expectEmit(true, true, true, true);
        emit SuperDCAGauge.InternalAddressUpdated(internalUser, false);
        hook.setInternalAddress(internalUser, false);

        assertFalse(hook.isInternalAddress(internalUser), "User should be marked as not internal");
    }

    function test_RevertWhen_NonManagerSetsInternalAddress() public {
        vm.expectRevert(
            abi.encodeWithSelector(ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, nonManagerUser, hook.MANAGER_ROLE())
        );
        vm.prank(nonManagerUser);
        hook.setInternalAddress(internalUser, true);
    }

    function test_RevertWhen_SettingZeroAddressAsInternal() public {
        vm.expectRevert("Cannot set zero address");
        vm.prank(managerUser);
        hook.setInternalAddress(address(0), true);
    }
}

// Note: These are commented out since the `msgSender` function is not
// implemented in the PoolSwapTest contract.
// TODO: https://github.com/Uniswap/v4-core/issues/967
//
// contract BeforeSwapTest is SuperDCAGaugeTest {
//     using SafeCast for uint256;

//     function setUp() public override {
//         super.setUp();

//         // Add initial liquidity to the pool
//         _modifyLiquidity(key, 100e18); // Add substantial liquidity
//     }

//     // Helper function for swapping dcaToken for weth using poolManager directly
//     function _swapDCAForWETH_PoolManager(address user, uint256 amountIn) internal returns (BalanceDelta) {
//         vm.startPrank(user);

//         // 1. User sends input token (dcaToken) to the poolManager
//         dcaToken.transfer(address(manager), amountIn);

//         // 2. User calls swap on poolManager
//         // Prank as user again for the swap call itself
//         BalanceDelta delta = swap(key, false, int256(amountIn), ZERO_BYTES);

//         vm.stopPrank();

//         return delta;
//     }

//     function test_BeforeSwap_AppliesFeesCorrectly_ForInternalUser() public {
//         // Mark internalUser
//         vm.prank(developer);
//         hook.setInternalAddress(address(this), true);

//         uint256 currency1Before = Currency.wrap(address(weth)).balanceOfSelf();

//         // Setup and swap
//         bool zeroForOne = true;
//         int256 amountSpecified = -1e10;
//         swapRouter.setMsgSender(address(this));
//         dcaToken.approve(address(swapRouter), 1e10);
//         swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

//         uint256 currency1After = Currency.wrap(address(weth)).balanceOfSelf();

//         // the fee is 0.05% so we should receive approximately 0.9995 of currency1
//         assertEq(currency1After - currency1Before, uint256(0.9995e10 - 1));
//     }

//     function test_BeforeSwap_AppliesFeesCorrectly_ForExternalUser() public {
//         // Mark externalUser
//         vm.prank(developer);
//         hook.setInternalAddress(address(this), false);

//         uint256 currency1Before = Currency.wrap(address(weth)).balanceOfSelf();

//         // Setup and swap
//         int256 amountSpecified = -1e10;
//         bool zeroForOne = true;
//         swapRouter.setMsgSender(address(this));
//         dcaToken.approve(address(swapRouter), 1e10);
//         swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

//         uint256 currency1After = Currency.wrap(address(weth)).balanceOfSelf();

//         // the fee is 0.50% so we should receive approximately 0.9950 of currency1
//         assertEq(currency1After - currency1Before, uint256(0.995e10 - 1));
//     }
// }
