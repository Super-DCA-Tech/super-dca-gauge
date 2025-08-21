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
import {PositionMintHelper} from "./utils/PositionMintHelper.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

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
    IAllowanceTransfer public permit2 = PERMIT2;
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
    using CurrencyLibrary for Currency;
    
    uint256 testNfpId;
    address recipient = address(0x1234);
    address owner = address(this);

    event FeesCollected(
        address indexed recipient, address indexed token0, address indexed token1, uint256 amount0, uint256 amount1
    );

    function setUp() public override {
        super.setUp();

        // Add substantial initial liquidity to support swaps
        _modifyLiquidity(key, 50e18);

        // Grant admin role to the test contract so it can call collectFees
        vm.startPrank(developer);
        hook.grantRole(hook.DEFAULT_ADMIN_ROLE(), address(this));
        vm.stopPrank();

        // Mint a real full-range position NFT using PositionMintHelper
        // First, approve tokens to Permit2 and PositionManager
        IERC20(Currency.unwrap(key.currency0)).approve(address(permit2), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).approve(address(permit2), type(uint256).max);
        
        permit2.approve(
            Currency.unwrap(key.currency0),
            address(posM),
            type(uint160).max,
            type(uint48).max
        );
        permit2.approve(
            Currency.unwrap(key.currency1), 
            address(posM),
            type(uint160).max,
            type(uint48).max
        );

        // Give test contract tokens for minting position
        deal(Currency.unwrap(key.currency0), address(this), 1000e18);
        deal(Currency.unwrap(key.currency1), address(this), 1000e18);

        // Mint a real full-range position NFT with substantial liquidity
        testNfpId = PositionMintHelper.mintFullRange(
            posM,
            key,
            50e18, // large liquidity
            address(this)
        );
        
        assertTrue(testNfpId > 0, "Should have minted a real NFT");
    }

    /**
     * @notice Generate fees by executing swaps in both directions
     * @param swapVolume The volume to swap to generate fees
     */
    function _generateFees(uint256 swapVolume) internal {
        // Give swap router tokens to execute swaps
        deal(Currency.unwrap(key.currency0), address(swapRouter), swapVolume * 2);
        deal(Currency.unwrap(key.currency1), address(swapRouter), swapVolume * 2);

        // Execute swap zeroForOne (exact input)
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapVolume),
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        
        // Execute reverse swap to generate more fees
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(swapVolume / 2),
                sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function test_collect_fees_success() public {
        // Generate fees by executing swaps
        _generateFees(10_000e18);

        // Setup recipient balance tracking
        address token0Addr = Currency.unwrap(key.currency0);
        address token1Addr = Currency.unwrap(key.currency1);
        
        uint256 balanceBefore0 = IERC20(token0Addr).balanceOf(recipient);
        uint256 balanceBefore1 = IERC20(token1Addr).balanceOf(recipient);

        // Call collectFees with real position
        hook.collectFees(testNfpId, recipient);

        // Verify balances increased (real fees collected)
        uint256 balanceAfter0 = IERC20(token0Addr).balanceOf(recipient);
        uint256 balanceAfter1 = IERC20(token1Addr).balanceOf(recipient);

        assertGt(balanceAfter0, balanceBefore0, "Token0 fees should have been collected");
        assertGt(balanceAfter1, balanceBefore1, "Token1 fees should have been collected");
        
        console.log("Fees collected - Token0:", balanceAfter0 - balanceBefore0);
        console.log("Fees collected - Token1:", balanceAfter1 - balanceBefore1);
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
}

contract ListTest is SuperDCAGaugeTest {
    uint256 testNfpId; // Real minted full-range position
    uint256 testNfpId2; // Real minted narrow-range position (for revert tests)
    uint256 testNfpIdLowLiquidity; // Real minted low liquidity position
    address otherToken = address(0xBEEF);
    PoolKey validKey;
    PoolKey invalidHookKey;
    PoolKey staticFeeKey;
    PoolKey nonDcaTokenKey;

    event TokenListed(address indexed token, uint256 indexed nftId, PoolKey key);

    function setUp() public override {
        super.setUp();

        // Set up token approvals for position minting
        IERC20(Currency.unwrap(key.currency0)).approve(address(permit2), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).approve(address(permit2), type(uint256).max);
        
        permit2.approve(
            Currency.unwrap(key.currency0),
            address(posM),
            type(uint160).max,
            type(uint48).max
        );
        permit2.approve(
            Currency.unwrap(key.currency1), 
            address(posM),
            type(uint160).max,
            type(uint48).max
        );

        // Give test contract tokens for minting positions
        deal(Currency.unwrap(key.currency0), address(this), 10000e18);
        deal(Currency.unwrap(key.currency1), address(this), 10000e18);

        // Valid key for listing (uses existing pool)
        validKey = key;

        // Create additional pool keys for different test scenarios
        invalidHookKey = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(dcaToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(0x1234)) // Wrong hook address
        });

        // Create static fee pool
        staticFeeKey = _createPoolKey(address(weth), address(dcaToken), 500);
        manager.initialize(staticFeeKey, SQRT_PRICE_1_1);

        // Create pool without DCA token
        nonDcaTokenKey = _createPoolKey(address(weth), otherToken, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        
        // Mint real positions for testing
        // 1. Valid full-range position with good liquidity
        testNfpId = PositionMintHelper.mintFullRange(
            posM,
            validKey,
            2500e18, // Above minimum liquidity
            address(this)
        );

        // 2. Narrow-range position (not full range) for revert test
        (int24 midTick, ) = (int24(0), int24(60)); // Narrow range around current price
        testNfpId2 = PositionMintHelper.mintCustomRange(
            posM,
            validKey,
            midTick - 60,
            midTick + 60,
            1000e18,
            address(this)
        );

        // 3. Low liquidity full-range position for revert test
        testNfpIdLowLiquidity = PositionMintHelper.mintFullRange(
            posM,
            validKey,
            100e18, // Below minimum liquidity threshold
            address(this)
        );

        // Verify positions were minted correctly
        assertTrue(testNfpId > 0, "Valid NFT should be minted");
        assertTrue(testNfpId2 > 0, "Narrow range NFT should be minted");
        assertTrue(testNfpIdLowLiquidity > 0, "Low liquidity NFT should be minted");
    }

    // Test 1: Successful listing with DCA token in pool
    function test_list_success_dcaTokenInPool() public {
        // Use the already minted valid position
        // The validKey already contains dcaToken as one of the currencies
        
        // Determine which token will be listed (the non-DCA token)
        address tokenToList = Currency.unwrap(validKey.currency0) == address(dcaToken)
            ? Currency.unwrap(validKey.currency1) 
            : Currency.unwrap(validKey.currency0);

        // Expect the event
        vm.expectEmit(true, true, false, true);
        emit TokenListed(tokenToList, testNfpId, validKey);

        // Execute listing
        hook.list(testNfpId, validKey);

        // Verify state changes
        assertTrue(hook.isTokenListed(tokenToList));
        assertEq(hook.tokenOfNfp(testNfpId), tokenToList);
    }

    // Test 2: Revert when position is not full range
    function test_list_revert_notFullRangePosition() public {
        vm.expectRevert(SuperDCAGauge.NotFullRangePosition.selector);
        hook.list(testNfpId2, validKey); // testNfpId2 is narrow range
    }

    // Test 3: Revert when nftId is zero
    function test_list_revert_zeroNftId() public {
        vm.expectRevert(SuperDCAGauge.UniswapTokenNotSet.selector);
        hook.list(0, validKey);
    }

    // Test 4: Revert when fee is not dynamic
    function test_list_revert_notDynamicFee() public {
        // Mint position in static fee pool
        uint256 staticFeeNftId = PositionMintHelper.mintFullRange(
            posM,
            staticFeeKey,
            1000e18,
            address(this)
        );
        
        vm.expectRevert(SuperDCAGauge.NotDynamicFee.selector);
        hook.list(staticFeeNftId, staticFeeKey);
    }

    // Test 5: Revert when hook address is incorrect  
    function test_list_revert_incorrectHookAddress() public {
        vm.expectRevert(SuperDCAGauge.IncorrectHookAddress.selector);
        hook.list(testNfpId, invalidHookKey); // invalidHookKey has wrong hook address
    }

    // Test 6: Revert when liquidity is too low
    function test_list_revert_lowLiquidity() public {
        vm.expectRevert(SuperDCAGauge.LowLiquidity.selector);
        hook.list(testNfpIdLowLiquidity, validKey); // testNfpIdLowLiquidity has low liquidity
    }

    // Test 7: Revert when pool doesn't include SuperDCAToken
    function test_list_revert_poolMustIncludeSuperDCAToken() public {
        // This test verifies that pools without DCA token cannot be initialized
        // The hook should reject initialization of pools that don't include superDCAToken
        // We expect a wrapped error since it comes from the hook's beforeInitialize
        vm.expectRevert(); // Catch any revert, since it will be wrapped
        manager.initialize(nonDcaTokenKey, SQRT_PRICE_1_1);
    }

    // Test 8: Revert when token is already listed
    function test_list_revert_tokenAlreadyListed() public {
        // First listing should succeed
        hook.list(testNfpId, validKey);

        // Create another position for the same pool/token
        uint256 anotherNftId = PositionMintHelper.mintFullRange(
            posM,
            validKey,
            2000e18,
            address(this)
        );

        // Second listing with different NFP but same token should fail
        vm.expectRevert(SuperDCAGauge.TokenAlreadyListed.selector);
        hook.list(anotherNftId, validKey);
    }
}
