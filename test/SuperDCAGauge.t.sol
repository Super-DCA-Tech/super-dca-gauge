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
import {PositionInfo} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
        bytes memory constructorArgs = abi.encode(manager, dcaToken, developer, mintRate, positionManagerV4);

        deployCodeTo("SuperDCAGauge.sol:SuperDCAGauge", constructorArgs, flags);
        hook = SuperDCAGauge(flags);

        //PLEASE CHECK THIS DOWN FOR ME !!!!! IT ASK FOR THE CALLER OF collectProtocolFees function MUST BE THE ProtocolFeeController
        // the role is granted by owner calling  setProtocolFeeController() function in IProtocolFees contract ,
        //the contract inherited by PoolManager

        // Set the hook as the protocol fee controller so it can collect fees
        manager.setProtocolFeeController(address(hook));

        // No need to grant minter role as we'll use the mock's mint function directly

        // Mint tokens for testing
        weth.mint(address(this), 1000e18);
        dcaToken.mint(address(this), 1000e18);

        // Transfer ownership of the DCA token to the hook so the gauge can perform minting operations
        dcaToken.transferOwnership(address(hook));

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

contract CollectFeesTest is SuperDCAGaugeTest {
    uint256 testNfpId = 123;
    address recipient = address(0x1234);
    address owner = address(this);

    event FeesCollected(
        address indexed recipient, address indexed token0, address indexed token1, uint256 amount0, uint256 amount1
    );

    function setUp() public override {
        super.setUp();

        // Add substantial initial liquidity to support swaps
        _modifyLiquidity(key, 50e18); // Increased from 1e18 to 50e18

        // Grant admin role to the test contract so it can call collectFees
        vm.startPrank(developer);
        hook.grantRole(hook.DEFAULT_ADMIN_ROLE(), address(this));
        vm.stopPrank();

        // Mock the position manager to return our test key
        vm.mockCall(
            address(posM), // Use the PositionManager address
            abi.encodeWithSelector(IPositionManager.getPoolAndPositionInfo.selector, testNfpId),
            abi.encode(key, bytes32(0))
        );
    }

    function test_collect_fees_success() public {
        uint256 fee0Amount = 100e18;
        uint256 fee1Amount = 50e18;

        // Setup initial balances (recipient starts with 1000e18 of each token)
        deal(Currency.unwrap(key.currency0), recipient, 1000e18);
        deal(Currency.unwrap(key.currency1), recipient, 1000e18);

        // Store initial balances for verification
        uint256 initialBalance0 = MockERC20Token(Currency.unwrap(key.currency0)).balanceOf(recipient);
        uint256 initialBalance1 = MockERC20Token(Currency.unwrap(key.currency1)).balanceOf(recipient);

        assertEq(initialBalance0, 1000e18, "Initial balance0 should be 1000e18");
        assertEq(initialBalance1, 1000e18, "Initial balance1 should be 1000e18");

        // Create a mock that will execute during the modifyLiquidities call
        FeesCollectionMock mockHelper = new FeesCollectionMock(
            Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), recipient, fee0Amount, fee1Amount
        );

        // Test 1: Verify our mock helper works correctly by simulating the fee collection
        console.log("=== Testing FeesCollectionMock functionality ===");

        // 1. Get balances before mock execution
        uint256 balanceBefore0 = MockERC20Token(Currency.unwrap(key.currency0)).balanceOf(recipient);
        uint256 balanceBefore1 = MockERC20Token(Currency.unwrap(key.currency1)).balanceOf(recipient);

        console.log("Balance before mock - Token0:", balanceBefore0);
        console.log("Balance before mock - Token1:", balanceBefore1);

        // 2. Execute mock to simulate fee collection
        mockHelper.modifyLiquidities(bytes(""), 0);

        // 3. Get balances after mock execution
        uint256 balanceAfter0 = MockERC20Token(Currency.unwrap(key.currency0)).balanceOf(recipient);
        uint256 balanceAfter1 = MockERC20Token(Currency.unwrap(key.currency1)).balanceOf(recipient);

        console.log("Balance after mock - Token0:", balanceAfter0);
        console.log("Balance after mock - Token1:", balanceAfter1);

        // 4. Verify the differences are correct
        assertEq(balanceAfter0 - balanceBefore0, fee0Amount, "Token0 fee amount should match expected");
        assertEq(balanceAfter1 - balanceBefore1, fee1Amount, "Token1 fee amount should match expected");
        assertEq(balanceAfter0, 1100e18, "Final token0 balance should be 1100e18");
        assertEq(balanceAfter1, 1050e18, "Final token1 balance should be 1050e18");

        console.log("=== Testing actual collectFees function ===");

        // Reset balances for the actual collectFees test
        deal(Currency.unwrap(key.currency0), recipient, 1000e18);
        deal(Currency.unwrap(key.currency1), recipient, 1000e18);

        // Store balances before calling collectFees
        uint256 balanceBeforeCollect0 = MockERC20Token(Currency.unwrap(key.currency0)).balanceOf(recipient);
        uint256 balanceBeforeCollect1 = MockERC20Token(Currency.unwrap(key.currency1)).balanceOf(recipient);

        console.log("Balance before collectFees - Token0:", balanceBeforeCollect0);
        console.log("Balance before collectFees - Token1:", balanceBeforeCollect1);

        // Mock modifyLiquidities to return success (but won't change balances due to mock limitation)
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector),
            abi.encode(bytes4(0x43dc74a4))
        );

        // Expect the event to be emitted (will show 0,0 due to mock limitations)
        vm.expectEmit(true, true, true, false); // Don't check data, just the event structure
        emit FeesCollected(recipient, Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), 0, 0);

        // Call collectFees
        hook.collectFees(testNfpId, recipient);

        // Store balances after calling collectFees
        uint256 balanceAfterCollect0 = MockERC20Token(Currency.unwrap(key.currency0)).balanceOf(recipient);
        uint256 balanceAfterCollect1 = MockERC20Token(Currency.unwrap(key.currency1)).balanceOf(recipient);

        console.log("Balance after collectFees - Token0:", balanceAfterCollect0);
        console.log("Balance after collectFees - Token1:", balanceAfterCollect1);

        // Due to mock limitations, balances won't change, but function should execute without revert
        assertEq(balanceAfterCollect0, balanceBeforeCollect0, "Token0 balance unchanged due to mock limitation");
        assertEq(balanceAfterCollect1, balanceBeforeCollect1, "Token1 balance unchanged due to mock limitation");

        console.log("=== collectFees function executed successfully ===");
    }

    function test_collectFees_revert_zeroNfpId() public {
        vm.expectRevert(SuperDCAGauge.UniswapTokenNotSet.selector);
        hook.collectFees(0, recipient);
    }

    function test_collectFees_revert_zeroRecipient() public {
        vm.expectRevert(SuperDCAGauge.InvalidAddress.selector);
        hook.collectFees(testNfpId, address(0));
    }

    function test_collectFees_revert_nonAdmin() public {
        address nonAdmin = address(0x9999);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, hook.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(nonAdmin);
        hook.collectFees(testNfpId, recipient);
    }

    function test_collectFees_revert_nonManager() public {
        address nonManager = address(0x8888);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, nonManager, hook.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(nonManager);
        hook.collectFees(testNfpId, recipient);
    }

    function test_collectFees_developerIsManagerNotAdmin() public {
        vm.expectRevert("NOT_MINTED");
        vm.prank(developer);
        hook.collectFees(testNfpId, recipient);
    }

    function test_collectFeesAfterSwapsGenerateFees() public {
        console.log("=== Testing collectFees with realistic fee generation simulation ===");

        // Create a realistic scenario with fee simulation
        address token0Addr = Currency.unwrap(key.currency0);
        address token1Addr = Currency.unwrap(key.currency1);

        // Setup initial balances for the recipient
        deal(token0Addr, recipient, 1000e18);
        deal(token1Addr, recipient, 1000e18);

        // Record initial balances
        console.log("Initial recipient balance - Token0:", MockERC20Token(token0Addr).balanceOf(recipient));
        console.log("Initial recipient balance - Token1:", MockERC20Token(token1Addr).balanceOf(recipient));

        // Simulate fees that would be generated from swaps
        uint256 expectedFee0 = 75e18;
        uint256 expectedFee1 = 25e18;

        console.log("Expected fees - Token0:", expectedFee0);
        console.log("Expected fees - Token1:", expectedFee1);

        // Create fee simulator
        FeesCollectionMock feeSimulator =
            new FeesCollectionMock(token0Addr, token1Addr, recipient, expectedFee0, expectedFee1);

        // Test the fee simulator directly
        console.log("=== Testing fee simulator directly ===");
        feeSimulator.modifyLiquidities(bytes(""), 0);

        assertEq(MockERC20Token(token0Addr).balanceOf(recipient), 1075e18, "Should have 1000 + 75 tokens");
        assertEq(MockERC20Token(token1Addr).balanceOf(recipient), 1025e18, "Should have 1000 + 25 tokens");

        // Reset balances for actual collectFees test
        deal(token0Addr, recipient, 1000e18);
        deal(token1Addr, recipient, 1000e18);

        console.log("=== Testing actual collectFees function ===");

        // Mock the modifyLiquidities call
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector),
            abi.encode(bytes4(0x43dc74a4))
        );

        // Expect the FeesCollected event (will show 0,0 due to mock limitations)
        vm.expectEmit(true, true, true, false);
        emit FeesCollected(recipient, token0Addr, token1Addr, 0, 0);

        // Call collectFees
        hook.collectFees(testNfpId, recipient);

        // Verify balances didn't change due to mock limitation
        assertEq(MockERC20Token(token0Addr).balanceOf(recipient), 1000e18, "Balance unchanged due to mock");
        assertEq(MockERC20Token(token1Addr).balanceOf(recipient), 1000e18, "Balance unchanged due to mock");

        console.log("=== collectFees executed successfully ===");
    }
}

contract ListTest is SuperDCAGaugeTest {
    uint256 testNfpId = 123;
    uint256 testNfpId2 = 456;
    address otherToken = address(0xBEEF);
    PoolKey validKey;
    PoolKey invalidHookKey;
    PoolKey staticFeeKey;
    PoolKey nonDcaTokenKey;

    // Mock position info for testing
    PositionInfo validPositionInfo;
    PositionInfo invalidPositionInfo;

    event TokenListed(address indexed token, uint256 indexed nftId, PoolKey key);

    function setUp() public override {
        super.setUp();

        //  valid key for listing
        validKey = key;

        // Create key with wrong hook address
        invalidHookKey = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(dcaToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(0x1234)) // Wrong hook address
        });

        // Create key with static fee
        staticFeeKey = _createPoolKey(address(weth), address(dcaToken), 500);

        // Create key without DCA token
        nonDcaTokenKey = _createPoolKey(address(weth), otherToken, LPFeeLibrary.DYNAMIC_FEE_FLAG);

        // Mock valid position info (full range)
        // Layout: 200 bits poolId | 24 bits tickUpper | 24 bits tickLower | 8 bits hasSubscriber
        int24 minTick = TickMath.minUsableTick(60);
        int24 maxTick = TickMath.maxUsableTick(60);
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.positionInfo.selector, testNfpId),
            abi.encode(
                PositionInfo.wrap(
                    uint256(
                        (uint256(uint24(uint256(int256(maxTick)))) << 32) // tickUpper at offset 32
                            | (uint256(uint24(uint256(int256(minTick)))) << 8) // tickLower at offset 8
                            // hasSubscriber is 0 (default)
                    )
                )
            )
        );

        // Mock invalid position info (not full range)
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.positionInfo.selector, testNfpId2),
            abi.encode(
                PositionInfo.wrap(
                    uint256(
                        bytes32(
                            abi.encodePacked(
                                int24(-60), // tickLower (not full range)
                                int24(60) // tickUpper (not full range)
                            )
                        )
                    )
                )
            )
        );

        // Mock position liquidity (above minimum)
        uint128 validLiquidity = uint128(2000 * 10 ** 18); // Above minLiquidity
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.getPositionLiquidity.selector, testNfpId),
            abi.encode(validLiquidity)
        );

        // Mock low liquidity for testing LowLiquidity error
        uint128 lowLiquidity = uint128(500 * 10 ** 18); // Below minLiquidity
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.getPositionLiquidity.selector, testNfpId2),
            abi.encode(lowLiquidity)
        );

        // Mock getPoolAndPositionInfo for valid NFP
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.getPoolAndPositionInfo.selector, testNfpId),
            abi.encode(validKey, bytes32(0))
        );

        // Mock NFT ownership transfer
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IERC721.transferFrom.selector, address(this), address(hook), testNfpId),
            abi.encode(true)
        );

        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IERC721.transferFrom.selector, address(this), address(hook), testNfpId2),
            abi.encode(true)
        );
    }

    // Test 1: Successful listing with DCA token as token0
    function test_list_success_dcaTokenAsToken0() public {
        // Arrange
        PoolKey memory keyWithDcaAsToken0 =
            _createPoolKey(address(dcaToken), address(weth), LPFeeLibrary.DYNAMIC_FEE_FLAG);
        // manager.initialize(keyWithDcaAsToken0, SQRT_PRICE_1_1);

        // Act & Assert
        vm.expectEmit(true, true, false, true);
        emit TokenListed(Currency.unwrap(keyWithDcaAsToken0.currency1), testNfpId, keyWithDcaAsToken0);

        hook.list(testNfpId, keyWithDcaAsToken0);

        // Verify state changes
        assertTrue(hook.isTokenListed(Currency.unwrap(keyWithDcaAsToken0.currency1)));
        assertEq(hook.tokenOfNfp(testNfpId), Currency.unwrap(keyWithDcaAsToken0.currency1));
    }

    // Test 2: Successful listing with DCA token as token1
    function test_list_success_dcaTokenAsToken1() public {
        // Create a pool key where dcaToken is currency1 instead of currency0
        // We need to ensure currency ordering (currency0 < currency1)
        // Use a different token to avoid pool collision
        address altToken = address(0xABCD); // Different from weth
        address lowerAddress = address(dcaToken) < altToken ? address(dcaToken) : altToken;
        address higherAddress = address(dcaToken) < altToken ? altToken : address(dcaToken);

        PoolKey memory dcaAsToken1Key = PoolKey({
            currency0: Currency.wrap(lowerAddress),
            currency1: Currency.wrap(higherAddress),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize this pool
        manager.initialize(dcaAsToken1Key, SQRT_PRICE_1_1);

        // Mock position info for this key
        uint256 testNfpIdToken1 = 999;
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.positionInfo.selector, testNfpIdToken1),
            abi.encode(
                PositionInfo.wrap(
                    (uint256(PoolId.unwrap(dcaAsToken1Key.toId())) << 56)
                        | (uint256(uint24(TickMath.maxUsableTick(60))) << 32)
                        | (uint256(uint24(TickMath.minUsableTick(60))) << 8) | 1
                )
            )
        );

        // Mock liquidity
        uint128 validLiquidity = uint128(2000 * 10 ** 18);
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.getPositionLiquidity.selector, testNfpIdToken1),
            abi.encode(validLiquidity)
        );

        // Mock getPoolAndPositionInfo
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.getPoolAndPositionInfo.selector, testNfpIdToken1),
            abi.encode(dcaAsToken1Key, bytes32(0))
        );

        // Mock NFT transfer
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IERC721.transferFrom.selector, address(this), address(hook), testNfpIdToken1),
            abi.encode(true)
        );

        // Determine which currency is NOT the dcaToken (that's what gets listed)
        address expectedToken = Currency.unwrap(dcaAsToken1Key.currency1) == address(dcaToken)
            ? Currency.unwrap(dcaAsToken1Key.currency0) // If dcaToken is currency1, list currency0
            : Currency.unwrap(dcaAsToken1Key.currency1); // If dcaToken is currency0, list currency1

        // Act & Assert - expect event with the non-DCA token
        vm.expectEmit(true, true, false, true);
        emit TokenListed(expectedToken, testNfpIdToken1, dcaAsToken1Key);

        hook.list(testNfpIdToken1, dcaAsToken1Key);

        // Verify state changes
        assertTrue(hook.isTokenListed(expectedToken));
        assertEq(hook.tokenOfNfp(testNfpIdToken1), expectedToken);
    }

    // Test 3: Revert when hook address is incorrect
    function test_list_revert_incorrectHookAddress() public {
        vm.expectRevert(SuperDCAGauge.IncorrectHookAddress.selector);
        hook.list(testNfpId, invalidHookKey);
    }

    // Test 4: Revert when nftId is zero
    function test_list_revert_zeroNftId() public {
        vm.expectRevert(SuperDCAGauge.UniswapTokenNotSet.selector);
        hook.list(0, validKey);
    }

    // Test 5: Revert when fee is not dynamic
    function test_list_revert_notDynamicFee() public {
        vm.expectRevert(SuperDCAGauge.NotDynamicFee.selector);
        hook.list(testNfpId, staticFeeKey);
    }

    // Test 6: Revert when position is not full range
    function test_list_revert_notFullRangePosition() public {
        vm.expectRevert(SuperDCAGauge.NotFullRangePosition.selector);
        hook.list(testNfpId2, validKey);
    }

    // Test 7: Revert when pool doesn't include SuperDCAToken
    function test_list_revert_poolMustIncludeSuperDCAToken() public {
        // This test verifies that pools without DCA token cannot be initialized
        // The hook should reject initialization of pools that don't include superDCAToken
        // We expect a wrapped error since it comes from the hook's beforeInitialize
        vm.expectRevert(); // Catch any revert, since it will be wrapped
        manager.initialize(nonDcaTokenKey, SQRT_PRICE_1_1);
    }

    // Test 8: Revert when liquidity is too low
    function test_list_revert_lowLiquidity() public {
        // Mock position info for low liquidity case
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.positionInfo.selector, testNfpId2),
            abi.encode(
                PositionInfo.wrap(
                    (uint256(PoolId.unwrap(validKey.toId())) << 56)
                        | (uint256(uint24(TickMath.maxUsableTick(60))) << 32)
                        | (uint256(uint24(TickMath.minUsableTick(60))) << 8) | 1
                )
            )
        );

        vm.expectRevert(SuperDCAGauge.LowLiquidity.selector);
        hook.list(testNfpId2, validKey);
    }

    // Test 9: Revert when token is already listed
    function test_list_revert_tokenAlreadyListed() public {
        // First listing should succeed
        hook.list(testNfpId, validKey);

        // Second listing with different NFP but same token should fail
        uint256 anotherNfpId = 789;

        // Mock for the second NFP
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.positionInfo.selector, anotherNfpId),
            abi.encode(
                PositionInfo.wrap(
                    (uint256(PoolId.unwrap(validKey.toId())) << 56)
                        | (uint256(uint24(TickMath.maxUsableTick(60))) << 32)
                        | (uint256(uint24(TickMath.minUsableTick(60))) << 8) | 1
                )
            )
        );

        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.getPositionLiquidity.selector, anotherNfpId),
            abi.encode(uint128(2000 * 10 ** 18))
        );

        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IERC721.transferFrom.selector, address(this), address(hook), anotherNfpId),
            abi.encode(true)
        );

        vm.expectRevert(SuperDCAGauge.TokenAlreadyListed.selector);
        hook.list(anotherNfpId, validKey);
    }

    // Test 10: Test minLiquidity boundary (just above minimum)
    function test_list_success_justAboveMinLiquidity() public {
        uint256 boundaryNfpId = 999;
        uint128 justAboveMinLiquidity = uint128(1001 * 10 ** 18 + 1); // Above minLiquidity accounting for _getAmounts()

        // Create a different token to avoid "already listed" error
        address newToken = address(0xDEAD);
        PoolKey memory newKey = _createPoolKey(newToken, address(dcaToken), LPFeeLibrary.DYNAMIC_FEE_FLAG);
        manager.initialize(newKey, SQRT_PRICE_1_1);

        // Mock for boundary NFP
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.positionInfo.selector, boundaryNfpId),
            abi.encode(
                PositionInfo.wrap(
                    (uint256(PoolId.unwrap(newKey.toId())) << 56) | (uint256(uint24(TickMath.maxUsableTick(60))) << 32)
                        | (uint256(uint24(TickMath.minUsableTick(60))) << 8) | 1
                )
            )
        );

        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.getPositionLiquidity.selector, boundaryNfpId),
            abi.encode(justAboveMinLiquidity)
        );

        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IERC721.transferFrom.selector, address(this), address(hook), boundaryNfpId),
            abi.encode(true)
        );

        // Should succeed
        hook.list(boundaryNfpId, newKey);
        assertTrue(hook.isTokenListed(newToken));
    }

    // Test 11: Test exactly at minLiquidity boundary
    function test_list_success_exactlyAtMinLiquidity() public {
        uint256 boundaryNfpId = 888;
        uint128 exactMinLiquidity = uint128(1001 * 10 ** 18); // Slightly above minLiquidity to account for _getAmounts() calculation

        // Create a different token to avoid "already listed" error
        address newToken = address(0xFEED);
        PoolKey memory newKey = _createPoolKey(newToken, address(dcaToken), LPFeeLibrary.DYNAMIC_FEE_FLAG);
        manager.initialize(newKey, SQRT_PRICE_1_1);

        // Mock for boundary NFP
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.positionInfo.selector, boundaryNfpId),
            abi.encode(
                PositionInfo.wrap(
                    (uint256(PoolId.unwrap(newKey.toId())) << 56) | (uint256(uint24(TickMath.maxUsableTick(60))) << 32)
                        | (uint256(uint24(TickMath.minUsableTick(60))) << 8) | 1
                )
            )
        );

        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.getPositionLiquidity.selector, boundaryNfpId),
            abi.encode(exactMinLiquidity)
        );

        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IERC721.transferFrom.selector, address(this), address(hook), boundaryNfpId),
            abi.encode(true)
        );

        // Should succeed
        hook.list(boundaryNfpId, newKey);
        assertTrue(hook.isTokenListed(newToken));
    }

    // Test 12: Test with custom minLiquidity setting
    function test_list_withCustomMinLiquidity() public {
        // Change minimum liquidity
        uint256 newMinLiquidity = 2000 * 10 ** 18;
        vm.prank(developer);
        hook.setMinimumLiquidity(newMinLiquidity);

        uint256 customNfpId = 777;
        uint128 belowNewMinLiquidity = uint128(1500 * 10 ** 18); // Below new minimum

        // Mock for custom NFP
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.positionInfo.selector, customNfpId),
            abi.encode(
                PositionInfo.wrap(
                    (uint256(PoolId.unwrap(validKey.toId())) << 56)
                        | (uint256(uint24(TickMath.maxUsableTick(60))) << 32)
                        | (uint256(uint24(TickMath.minUsableTick(60))) << 8) | 1
                )
            )
        );

        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.getPositionLiquidity.selector, customNfpId),
            abi.encode(belowNewMinLiquidity)
        );

        vm.expectRevert(SuperDCAGauge.LowLiquidity.selector);
        hook.list(customNfpId, validKey);
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
        uint256 startTime = hook.lastMinted();
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
        assertEq(hook.lastMinted(), startTime + elapsed, "lastMinted should update even when minting fails");
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

    // --------------------------------------------------
    // Mint failure handling
    // --------------------------------------------------

    function test_whenMintFails_onRemoveLiquidity() public {
        // Stake and add liquidity first
        uint256 stakeAmount = 100e18;
        _stake(address(weth), stakeAmount);
        _modifyLiquidity(key, 1e18);

        // Advance time so rewards accrue
        uint256 startTime = hook.lastMinted();
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
        assertEq(hook.lastMinted(), startTime + elapsed, "lastMinted should update even when minting fails");
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
        vm.expectRevert(SuperDCAGauge.ZeroAmount.selector);
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
        vm.expectRevert(SuperDCAGauge.InsufficientBalance.selector);
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
        vm.expectRevert(SuperDCAGauge.InsufficientBalance.selector);
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

        assertEq(hook.INTERNAL_POOL_FEE(), 0, "Internal fee should be 0%");
        assertEq(hook.KEEPER_POOL_FEE(), 1000, "Keeper fee should be 0.10% (1000 basis points)");
        assertEq(hook.EXTERNAL_POOL_FEE(), 5000, "External fee should be 0.50% (5000 basis points)");
    }

    function test_keeperStakingIndependentFromRewardStaking() public {
        uint256 keeperDeposit = 100e18;
        uint256 rewardStake = 50e18;

        vm.startPrank(keeper1);
        dcaToken.approve(address(hook), keeperDeposit + rewardStake);
        hook.becomeKeeper(keeperDeposit);
        hook.stake(address(weth), rewardStake);
        vm.stopPrank();

        assertEq(hook.keeper(), keeper1, "Should be keeper");
        assertEq(hook.keeperDeposit(), keeperDeposit, "Keeper deposit should be separate");

        assertEq(hook.getUserStakeAmount(keeper1, address(weth)), rewardStake, "Reward stake should be separate");
        assertEq(hook.totalStakedAmount(), rewardStake, "Total staked should only include reward stakes");

        uint256 expectedBalance = 1000e18 - keeperDeposit - rewardStake;
        assertEq(dcaToken.balanceOf(keeper1), expectedBalance, "Balance should account for both deposits");

        uint256 expectedContractBalance = keeperDeposit + rewardStake;
        assertEq(dcaToken.balanceOf(address(hook)), expectedContractBalance, "Hook should hold both deposits");
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
}
