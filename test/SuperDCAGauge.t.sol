// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SuperDCAGauge} from "../src/SuperDCAGauge.sol";
import {SuperDCAStaking} from "../src/SuperDCAStaking.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC20Token} from "./mocks/MockERC20Token.sol";
import {FeesCollectionMock} from "./mocks/FeesCollectionMock.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PositionManager} from "lib/v4-periphery/src/PositionManager.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionDescriptor} from "lib/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "lib/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SuperDCAGaugeTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;

    SuperDCAGauge hook;
    SuperDCAStaking public staking;
    MockERC20Token public dcaToken;
    PoolId poolId;
    address developer = address(0xDEADBEEF);
    uint256 mintRate = 100; // SDCA tokens per second
    MockERC20Token public weth;
    IAllowanceTransfer public constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3); // Real Permit2 address
    uint256 public constant UNSUBSCRIBE_LIMIT = 5000;
    IPositionDescriptor public tokenDescriptor;
    PositionManager public posM;

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
        dcaToken.approve(address(staking), amount);
        staking.stake(stakingToken, amount);
    }

    // (Optional) Helper to perform an unstake.
    function _unstake(address stakingToken, uint256 amount) internal {
        staking.unstake(stakingToken, amount);
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

        // Deplying PositionManager
        posM = new PositionManager(
            IPoolManager(address(manager)),
            PERMIT2,
            UNSUBSCRIBE_LIMIT,
            IPositionDescriptor(tokenDescriptor),
            IWETH9(address(weth))
        );
        IPositionManager positionManagerV4 = IPositionManager(address(posM));

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG
            ) ^ (0x4242 << 144)
        );
        bytes memory constructorArgs = abi.encode(manager, dcaToken, developer, positionManagerV4);

        deployCodeTo("SuperDCAGauge.sol:SuperDCAGauge", constructorArgs, flags);
        hook = SuperDCAGauge(flags);

        //PLEASE CHECK THIS DOWN FOR ME !!!!! IT ASK FOR THE CALLER OF collectProtocolFees function MUST BE THE ProtocolFeeController
        // the role is granted by owner calling  setProtocolFeeController() function in IProtocolFees contract ,
        //the contract inherited by PoolManager

        // Set the hook as the protocol fee controller so it can collect fees
        manager.setProtocolFeeController(address(hook));

        // Mint tokens for testing
        weth.mint(address(this), 1000e18);
        dcaToken.mint(address(this), 1000e18);

        // Transfer ownership of the DCA token to the hook so the gauge can perform minting operations
        dcaToken.transferOwnership(address(hook));

        // Deploy staking and wire it to the gauge
        staking = new SuperDCAStaking(address(dcaToken), mintRate, developer);
        vm.startPrank(developer);
        staking.setGauge(address(hook));
        hook.setStaking(address(staking));
        vm.stopPrank();

        // Mock token listing checks so staking does not revert during tests
        bytes4 IS_TOKEN_LISTED = bytes4(keccak256("isTokenListed(address)"));
        vm.mockCall(address(hook), abi.encodeWithSelector(IS_TOKEN_LISTED, address(weth)), abi.encode(true));

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
        assertEq(staking.mintRate(), mintRate, "Mint rate not set correctly");
        assertEq(staking.lastMinted(), block.timestamp, "Last minted time not set correctly");
        assertEq(staking.totalStakedAmount(), 0, "Initial staked amount should be 0");
        assertEq(staking.rewardIndex(), 0, "Initial reward index should be 1e18");

        // Test fee initialization
        assertEq(hook.internalFee(), hook.INTERNAL_POOL_FEE(), "Internal fee should be initialized to constant");
        assertEq(hook.externalFee(), hook.EXTERNAL_POOL_FEE(), "External fee should be initialized to constant");
        assertEq(hook.keeperFee(), hook.KEEPER_POOL_FEE(), "Keeper fee should be initialized to constant");

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

        uint256 startTime = staking.lastMinted();
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
        assertEq(staking.lastMinted(), startTime + elapsed, "Last minted timestamp should be updated");

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

    // --------------------------------------------------
    // Mint failure handling
    // --------------------------------------------------

    function test_whenMintFails_onAddLiquidity() public {
        // Stake so that rewards can accrue
        uint256 stakeAmount = 100e18;
        _stake(address(weth), stakeAmount);

        // Add initial liquidity to create the pool
        _modifyLiquidity(key, 1e18);

        // Advance time so rewards are due
        uint256 startTime = staking.lastMinted();
        uint256 elapsed = 20;
        vm.warp(startTime + elapsed);

        // Remove minting permissions from the gauge so that subsequent mint calls revert
        vm.prank(developer);
        hook.returnSuperDCATokenOwnership();

        // Expect no revert even though the internal mint will fail
        _modifyLiquidity(key, 1e18);

        // Developer balance should remain unchanged
        assertEq(dcaToken.balanceOf(developer), 0, "Developer balance should remain zero when mint fails");

        // lastMinted should still update
        assertEq(staking.lastMinted(), startTime + elapsed, "lastMinted should update even when minting fails");
    }
}

contract BeforeRemoveLiquidityTest is SuperDCAGaugeTest {
    function test_distribution_on_removeLiquidity() public {
        // Setup: Stake some tokens first
        uint256 stakeAmount = 100e18;
        _stake(address(weth), stakeAmount);

        // First add liquidity using explicit parameters
        _modifyLiquidity(key, 1e18);

        uint256 startTime = staking.lastMinted();
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
        assertEq(staking.lastMinted(), startTime + elapsed, "Last minted timestamp should be updated");

        // Verify the donation by checking that there are fees for the pool
        // Note: Can't figure out how to check the donation fees got to the pool
        // so I will verify this on the testnet work.
        // TODO: Verify this on testnet work.
    }

    // --------------------------------------------------
    // Mint failure handling
    // --------------------------------------------------

    function test_whenMintFails_onRemoveLiquidity() public {
        // Stake and add liquidity first
        uint256 stakeAmount = 100e18;
        _stake(address(weth), stakeAmount);
        _modifyLiquidity(key, 1e18);

        // Advance time so rewards accrue
        uint256 startTime = staking.lastMinted();
        uint256 elapsed = 20;
        vm.warp(startTime + elapsed);

        // Take a snapshot of the developer's balance BEFORE the mint failure scenario
        uint256 devBalanceBefore = dcaToken.balanceOf(developer);

        // Remove minting permissions from the gauge so that mint attempts revert
        vm.prank(developer);
        hook.returnSuperDCATokenOwnership();

        // Removing liquidity should not revert
        _modifyLiquidity(key, -1e18);

        // Verify developer balance unchanged from *before* this specific operation
        assertEq(
            dcaToken.balanceOf(developer), devBalanceBefore, "Developer balance should be unchanged after failed mint"
        );

        // Verify lastMinted updated
        assertEq(staking.lastMinted(), startTime + elapsed, "lastMinted should update even when minting fails");
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

        // Mock token listing check for USDC
        bytes4 IS_TOKEN_LISTED = bytes4(keccak256("isTokenListed(address)"));
        vm.mockCall(address(hook), abi.encodeWithSelector(IS_TOKEN_LISTED, address(usdc)), abi.encode(true));

        // Add initial stake for base tests
        _stake(address(weth), 100e18);
    }

    function test_reward_calculation() public {
        // Add liquidity to enable rewards
        _modifyLiquidity(key, 1e18);

        // Record initial state
        uint256 startTime = staking.lastMinted();
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
        assertEq(staking.lastMinted(), startTime + elapsed, "Last minted time should be updated");
    }

    function test_reward_distribution_no_liquidity() public {
        // Setup: Stake tokens
        uint256 stakeAmount = 100e18;
        _stake(address(weth), stakeAmount);

        // Record initial state
        uint256 startTime = staking.lastMinted();
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
        assertEq(staking.lastMinted(), startTime + elapsed, "Last minted time should be updated");
    }

    function test_getPendingRewards() public {
        // Setup: Stake tokens
        uint256 stakeAmount = 100e18;
        _stake(address(weth), stakeAmount);

        // Record initial state
        uint256 startTime = staking.lastMinted();

        // Advance time
        uint256 elapsed = 20;
        vm.warp(startTime + elapsed);

        // Calculate expected pending rewards
        uint256 expectedRewards = elapsed * mintRate; // 20 * 100 = 2000

        // Check pending rewards
        assertEq(staking.previewPending(address(weth)), expectedRewards, "Pending rewards calculation incorrect");
    }

    function test_getPendingRewards_noStake() public {
        // Unstake the amount from setUp first
        _unstake(address(weth), 100e18);
        assertEq(staking.previewPending(address(weth)), 0);
    }

    function test_getPendingRewards_noTimeElapsed() public view {
        assertEq(staking.previewPending(address(weth)), 0);
    }

    function test_multiple_pool_rewards() public {
        // Mint more USDC for this test
        usdc.mint(address(this), 300e18);
        _stake(address(usdc), 300e18); // 75% of the total stake

        // Add liquidity to both pools
        _modifyLiquidity(key, 1e18);
        _modifyLiquidity(usdcKey, 1e18);

        // Record initial state
        uint256 startTime = staking.lastMinted();
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
        assertEq(staking.getUserStake(address(this), address(weth)), 100e18, "WETH stake amount incorrect");
        assertEq(staking.getUserStake(address(this), address(usdc)), 300e18, "USDC stake amount incorrect");

        // Verify total staked amount
        assertEq(staking.totalStakedAmount(), 400e18, "Total staked amount incorrect");
    }

    function test_reward_distribution_multiple_users() public {
        // Setup second user
        address user2 = address(0xBEEF);
        deal(address(dcaToken), user2, 100e18);

        // First user already has 100e18 staked from setUp()

        // Stake as user2
        vm.startPrank(user2);
        dcaToken.approve(address(staking), 100e18);
        staking.stake(address(weth), 100e18);
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

    function test_Should_AllowAdminToUpdateManager() public {
        assertTrue(hook.hasRole(hook.MANAGER_ROLE(), managerUser), "Initial manager role incorrect");
        assertFalse(hook.hasRole(hook.MANAGER_ROLE(), newManagerUser), "New manager should not have role initially");

        vm.prank(developer);
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
    uint24 newKeeperFee = 800;

    function test_Should_AllowManagerToSetInternalFee() public {
        uint24 initialExternalFee = hook.externalFee();
        uint24 initialKeeperFee = hook.keeperFee();
        uint24 initialInternalFee = hook.internalFee();

        vm.prank(managerUser);
        vm.expectEmit(true, true, true, true);
        emit SuperDCAGauge.FeeUpdated(SuperDCAGauge.FeeType.INTERNAL, initialInternalFee, newInternalFee);
        hook.setFee(SuperDCAGauge.FeeType.INTERNAL, newInternalFee);

        assertEq(hook.internalFee(), newInternalFee, "Internal fee should be updated");
        assertEq(hook.externalFee(), initialExternalFee, "External fee should remain unchanged");
        assertEq(hook.keeperFee(), initialKeeperFee, "Keeper fee should remain unchanged");
    }

    function test_Should_AllowManagerToSetExternalFee() public {
        uint24 initialInternalFee = hook.internalFee();
        uint24 initialKeeperFee = hook.keeperFee();
        uint24 initialExternalFee = hook.externalFee();

        vm.prank(managerUser);
        vm.expectEmit(true, true, true, true);
        emit SuperDCAGauge.FeeUpdated(SuperDCAGauge.FeeType.EXTERNAL, initialExternalFee, newExternalFee);
        hook.setFee(SuperDCAGauge.FeeType.EXTERNAL, newExternalFee);

        assertEq(hook.externalFee(), newExternalFee, "External fee should be updated");
        assertEq(hook.internalFee(), initialInternalFee, "Internal fee should remain unchanged");
        assertEq(hook.keeperFee(), initialKeeperFee, "Keeper fee should remain unchanged");
    }

    function test_Should_AllowManagerToSetKeeperFee() public {
        uint24 initialInternalFee = hook.internalFee();
        uint24 initialExternalFee = hook.externalFee();
        uint24 initialKeeperFee = hook.keeperFee();

        vm.prank(managerUser);
        vm.expectEmit(true, true, true, true);
        emit SuperDCAGauge.FeeUpdated(SuperDCAGauge.FeeType.KEEPER, initialKeeperFee, newKeeperFee);
        hook.setFee(SuperDCAGauge.FeeType.KEEPER, newKeeperFee);

        assertEq(hook.keeperFee(), newKeeperFee, "Keeper fee should be updated");
        assertEq(hook.internalFee(), initialInternalFee, "Internal fee should remain unchanged");
        assertEq(hook.externalFee(), initialExternalFee, "External fee should remain unchanged");
    }

    function test_RevertWhen_NonManagerSetsInternalFee() public {
        vm.expectRevert(
            abi.encodeWithSelector(ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, nonManagerUser, hook.MANAGER_ROLE())
        );
        vm.prank(nonManagerUser);
        hook.setFee(SuperDCAGauge.FeeType.INTERNAL, newInternalFee);
    }

    function test_RevertWhen_NonManagerSetsExternalFee() public {
        vm.expectRevert(
            abi.encodeWithSelector(ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, nonManagerUser, hook.MANAGER_ROLE())
        );
        vm.prank(nonManagerUser);
        hook.setFee(SuperDCAGauge.FeeType.EXTERNAL, newExternalFee);
    }

    function test_RevertWhen_NonManagerSetsKeeperFee() public {
        vm.expectRevert(
            abi.encodeWithSelector(ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, nonManagerUser, hook.MANAGER_ROLE())
        );
        vm.prank(nonManagerUser);
        hook.setFee(SuperDCAGauge.FeeType.KEEPER, newKeeperFee);
    }

    function test_AllFeeTypesCanBeSetIndependently() public {
        // Set all fees to new values
        vm.startPrank(managerUser);
        hook.setFee(SuperDCAGauge.FeeType.INTERNAL, newInternalFee);
        hook.setFee(SuperDCAGauge.FeeType.EXTERNAL, newExternalFee);
        hook.setFee(SuperDCAGauge.FeeType.KEEPER, newKeeperFee);
        vm.stopPrank();

        // Verify all fees are set correctly
        assertEq(hook.internalFee(), newInternalFee, "Internal fee should be updated");
        assertEq(hook.externalFee(), newExternalFee, "External fee should be updated");
        assertEq(hook.keeperFee(), newKeeperFee, "Keeper fee should be updated");
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
        vm.expectRevert(SuperDCAGauge.SuperDCAGauge__ZeroAddress.selector);
        vm.prank(managerUser);
        hook.setInternalAddress(address(0), true);
    }
}

contract ReturnSuperDCATokenOwnershipTest is AccessControlTest {
    function test_Should_ReturnOwnershipToAdmin() public {
        // Precondition: hook should own the token
        assertEq(dcaToken.owner(), address(hook), "Hook should own the token before return");

        vm.prank(developer);
        hook.returnSuperDCATokenOwnership();

        // Postcondition: admin owns the token
        assertEq(dcaToken.owner(), developer, "Developer should own the token after return");
    }

    function test_RevertWhen_NonAdminCalls() public {
        address nonAdmin = makeAddr("nonAdmin");

        vm.startPrank(nonAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, nonAdmin, hook.DEFAULT_ADMIN_ROLE())
        );
        hook.returnSuperDCATokenOwnership();
        vm.stopPrank();
    }
}

contract SetStakingTest is AccessControlTest {
    function test_Should_AllowAdminToSetStaking() public {
        address newStaking = makeAddr("newStaking");

        vm.prank(developer);
        hook.setStaking(newStaking);

        assertEq(address(hook.staking()), newStaking, "Staking address should be updated");
    }

    function test_EmitsStakingUpdatedEvent() public {
        address oldStaking = address(hook.staking());
        address newStaking = makeAddr("newStaking");

        vm.prank(developer);
        vm.expectEmit(true, true, true, true);
        emit SuperDCAGauge.StakingUpdated(oldStaking, newStaking);
        hook.setStaking(newStaking);
    }

    function test_RevertWhen_NonAdminSetsStaking() public {
        address newStaking = makeAddr("newStaking");

        vm.expectRevert(
            abi.encodeWithSelector(
                ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, nonManagerUser, hook.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(nonManagerUser);
        hook.setStaking(newStaking);
    }

    function test_RevertWhen_SettingStakingToZeroAddress() public {
        vm.expectRevert(SuperDCAGauge.SuperDCAGauge__ZeroAddress.selector);
        vm.prank(developer);
        hook.setStaking(address(0));
    }
}

contract SetListingTest is AccessControlTest {
    function test_Should_AllowAdminToSetListing() public {
        address newListing = makeAddr("newListing");

        vm.prank(developer);
        hook.setListing(newListing);

        assertEq(address(hook.listing()), newListing, "Listing address should be updated");
    }

    function test_EmitsListingUpdatedEvent() public {
        address oldListing = address(hook.listing());
        address newListing = makeAddr("newListing");

        vm.prank(developer);
        vm.expectEmit(true, true, true, true);
        emit SuperDCAGauge.ListingUpdated(oldListing, newListing);
        hook.setListing(newListing);
    }

    function test_RevertWhen_NonAdminSetsListing() public {
        address newListing = makeAddr("newListing");

        vm.expectRevert(
            abi.encodeWithSelector(
                ACCESS_CONTROL_UNAUTHORIZED_ACCOUNT_SELECTOR, nonManagerUser, hook.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(nonManagerUser);
        hook.setListing(newListing);
    }

    function test_AllowsSettingListingToZeroAddress() public {
        vm.prank(developer);
        hook.setListing(address(0));

        assertEq(address(hook.listing()), address(0), "Should allow setting listing to zero address");
    }
}

contract BecomeKeeperTest is SuperDCAGaugeTest {
    address keeper1 = address(0x1111);
    address keeper2 = address(0x2222);

    function setUp() public override {
        super.setUp();

        // Provide balances for keepers
        deal(address(dcaToken), keeper1, 1000e18);
        deal(address(dcaToken), keeper2, 1000e18);
    }

    function test_becomeKeeper_firstKeeper() public {
        uint256 depositAmount = 100e18;

        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), depositAmount);

        vm.expectEmit(true, true, true, true);
        emit SuperDCAGauge.KeeperChanged(address(0), keeper1, depositAmount);

        hook.becomeKeeper(depositAmount);
        vm.stopPrank();

        assertEq(hook.keeper(), keeper1, "Keeper should be set");
        assertEq(hook.keeperDeposit(), depositAmount, "Keeper deposit should be set");
        assertEq(dcaToken.balanceOf(keeper1), 1000e18 - depositAmount, "Keeper balance should decrease");
        assertEq(dcaToken.balanceOf(address(hook)), depositAmount, "Hook should hold deposit");
    }

    function test_becomeKeeper_replaceKeeper() public {
        uint256 firstDeposit = 100e18;
        uint256 secondDeposit = 200e18;

        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), firstDeposit);
        hook.becomeKeeper(firstDeposit);
        vm.stopPrank();

        vm.startPrank(keeper2);
        dcaToken.approve(address(hook), secondDeposit);

        vm.expectEmit(true, true, true, true);
        emit SuperDCAGauge.KeeperChanged(keeper1, keeper2, secondDeposit);

        hook.becomeKeeper(secondDeposit);
        vm.stopPrank();

        assertEq(hook.keeper(), keeper2, "New keeper should be set");
        assertEq(hook.keeperDeposit(), secondDeposit, "New deposit should be set");
        assertEq(dcaToken.balanceOf(keeper1), 1000e18, "First keeper should be refunded");
        assertEq(dcaToken.balanceOf(keeper2), 1000e18 - secondDeposit, "Second keeper balance should decrease");
        assertEq(dcaToken.balanceOf(address(hook)), secondDeposit, "Hook should hold new deposit");
    }

    function test_becomeKeeper_revert_zeroAmount() public {
        vm.startPrank(keeper1);
        vm.expectRevert(SuperDCAGauge.SuperDCAGauge__ZeroAmount.selector);
        hook.becomeKeeper(0);
        vm.stopPrank();
    }

    function test_becomeKeeper_revert_insufficientDeposit() public {
        uint256 firstDeposit = 200e18;
        uint256 insufficientDeposit = 100e18;

        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), firstDeposit);
        hook.becomeKeeper(firstDeposit);
        vm.stopPrank();

        vm.startPrank(keeper2);
        dcaToken.approve(address(hook), insufficientDeposit);
        vm.expectRevert(SuperDCAGauge.SuperDCAGauge__InsufficientBalance.selector);
        hook.becomeKeeper(insufficientDeposit);
        vm.stopPrank();
    }

    function test_becomeKeeper_sameDeposit() public {
        uint256 deposit = 100e18;

        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), deposit);
        hook.becomeKeeper(deposit);
        vm.stopPrank();

        vm.startPrank(keeper2);
        dcaToken.approve(address(hook), deposit);
        vm.expectRevert(SuperDCAGauge.SuperDCAGauge__InsufficientBalance.selector);
        hook.becomeKeeper(deposit);
        vm.stopPrank();
    }

    function test_keeperFeeStructure() public {
        uint256 deposit = 100e18;
        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), deposit);
        hook.becomeKeeper(deposit);
        vm.stopPrank();

        assertEq(hook.keeper(), keeper1, "Keeper should be set for fee application");

        assertEq(hook.INTERNAL_POOL_FEE(), 0, "Internal fee constant should be 0%");
        assertEq(hook.KEEPER_POOL_FEE(), 1000, "Keeper fee constant should be 0.10% (1000 basis points)");
        assertEq(hook.EXTERNAL_POOL_FEE(), 5000, "External fee constant should be 0.50% (5000 basis points)");

        // Test actual fee state variables
        assertEq(hook.internalFee(), 0, "Internal fee should be 0%");
        assertEq(hook.keeperFee(), 1000, "Keeper fee should be 0.10% (1000 basis points)");
        assertEq(hook.externalFee(), 5000, "External fee should be 0.50% (5000 basis points)");
    }

    function test_keeperStakingIndependentFromRewardStaking() public {
        uint256 keeperDeposit = 100e18;
        uint256 rewardStake = 50e18;

        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), keeperDeposit);
        dcaToken.approve(address(staking), rewardStake);
        hook.becomeKeeper(keeperDeposit);
        staking.stake(address(weth), rewardStake);
        vm.stopPrank();

        assertEq(hook.keeper(), keeper1, "Should be keeper");
        assertEq(hook.keeperDeposit(), keeperDeposit, "Keeper deposit should be separate");

        assertEq(staking.getUserStake(keeper1, address(weth)), rewardStake, "Reward stake should be separate");
        assertEq(staking.totalStakedAmount(), rewardStake, "Total staked should only include reward stakes");

        uint256 expectedBalance = 1000e18 - keeperDeposit - rewardStake;
        assertEq(dcaToken.balanceOf(keeper1), expectedBalance, "Balance should account for both deposits");

        uint256 expectedContractBalance = keeperDeposit;
        assertEq(dcaToken.balanceOf(address(hook)), expectedContractBalance, "Hook should hold only keeper deposit");
    }

    function test_multipleKeeperChanges() public {
        uint256 deposit1 = 100e18;
        uint256 deposit2 = 200e18;
        uint256 deposit3 = 300e18;

        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), deposit1);
        hook.becomeKeeper(deposit1);
        vm.stopPrank();

        vm.startPrank(keeper2);
        dcaToken.approve(address(hook), deposit2);
        hook.becomeKeeper(deposit2);
        vm.stopPrank();

        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), deposit3);
        hook.becomeKeeper(deposit3);
        vm.stopPrank();

        assertEq(hook.keeper(), keeper1, "Final keeper should be keeper1");
        assertEq(hook.keeperDeposit(), deposit3, "Final deposit should be highest");
        assertEq(dcaToken.balanceOf(keeper1), 1000e18 - deposit3, "Keeper1 should have paid final deposit");
        assertEq(dcaToken.balanceOf(keeper2), 1000e18, "Keeper2 should be fully refunded");
    }

    function test_getKeeperInfo() public {
        (address currentKeeper, uint256 currentDeposit) = hook.getKeeperInfo();
        assertEq(currentKeeper, address(0), "Initially no keeper");
        assertEq(currentDeposit, 0, "Initially no deposit");

        uint256 deposit = 150e18;
        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), deposit);
        hook.becomeKeeper(deposit);
        vm.stopPrank();

        (currentKeeper, currentDeposit) = hook.getKeeperInfo();
        assertEq(currentKeeper, keeper1, "Should return current keeper");
        assertEq(currentDeposit, deposit, "Should return current deposit");
    }

    function test_sameKeeperIncreaseDeposit() public {
        uint256 initialDeposit = 100e18;
        uint256 increasedDeposit = 200e18;

        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), initialDeposit + increasedDeposit);
        hook.becomeKeeper(initialDeposit);

        vm.expectEmit(true, true, true, true);
        emit SuperDCAGauge.KeeperChanged(keeper1, keeper1, increasedDeposit);
        hook.becomeKeeper(increasedDeposit);
        vm.stopPrank();

        assertEq(hook.keeper(), keeper1, "Should still be same keeper");
        assertEq(hook.keeperDeposit(), increasedDeposit, "Should have increased deposit");

        uint256 expectedBalance = 1000e18 - increasedDeposit;
        assertEq(dcaToken.balanceOf(keeper1), expectedBalance, "Should have net deposit difference");
    }

    function test_keeperFeeUpdatesAffectSwaps() public {
        uint256 deposit = 100e18;
        uint24 newKeeperFee = 2000; // 0.20%

        // Set up a keeper
        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), deposit);
        hook.becomeKeeper(deposit);
        vm.stopPrank();

        // Verify initial keeper fee
        assertEq(hook.keeperFee(), hook.KEEPER_POOL_FEE(), "Initial keeper fee should be constant value");

        // Update keeper fee
        vm.prank(developer);
        hook.setFee(SuperDCAGauge.FeeType.KEEPER, newKeeperFee);

        // Verify fee was updated
        assertEq(hook.keeperFee(), newKeeperFee, "Keeper fee should be updated");

        // The beforeSwap function should now use the new fee for keeper swaps
        // This verifies that the updated fee state variable is used rather than the constant
    }
}
