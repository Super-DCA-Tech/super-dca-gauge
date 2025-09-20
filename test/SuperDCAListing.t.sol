// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PositionManager} from "lib/v4-periphery/src/PositionManager.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPositionDescriptor} from "lib/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "lib/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PositionInfo} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {MockERC20Token} from "./mocks/MockERC20Token.sol";
import {SuperDCAListing} from "../src/SuperDCAListing.sol";
import {FeesCollectionMock} from "./mocks/FeesCollectionMock.sol";

contract SuperDCAListingTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // system
    MockERC20Token public dcaToken;
    MockERC20Token public weth;
    PositionManager public posM;
    IPositionManager public positionManagerV4;
    SuperDCAListing public listing;
    // Use Deployers.key inherited field
    PoolId poolId;

    // permit2 real address used in tests elsewhere
    IAllowanceTransfer public constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    address developer = address(0xDEADBEEF);

    function _createPoolKey(address tokenA, address tokenB, uint24 fee) internal pure returns (PoolKey memory k) {
        return tokenA < tokenB
            ? PoolKey({
                currency0: Currency.wrap(tokenA),
                currency1: Currency.wrap(tokenB),
                fee: fee,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            })
            : PoolKey({
                currency0: Currency.wrap(tokenB),
                currency1: Currency.wrap(tokenA),
                fee: fee,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });
    }

    function setUp() public virtual {
        // tokens
        weth = new MockERC20Token("Wrapped Ether", "WETH", 18);
        dcaToken = new MockERC20Token("Super DCA Token", "SDCA", 18);

        // Deploy core Uniswap V4
        deployFreshManagerAndRouters();

        // PositionManager
        Deployers.deployMintAndApprove2Currencies();
        posM = new PositionManager(
            IPoolManager(address(manager)), PERMIT2, 5000, IPositionDescriptor(address(0)), IWETH9(address(weth))
        );
        positionManagerV4 = IPositionManager(address(posM));

        // Deploy listing; expected hook will be set later per-test
        listing = new SuperDCAListing(address(dcaToken), manager, positionManagerV4, developer, IHooks(address(0)));

        // Build a pool key with dynamic fee and assign hooks after computing flags deployment address for gauge-style
        key = _createPoolKey(address(weth), address(dcaToken), LPFeeLibrary.DYNAMIC_FEE_FLAG);
        poolId = key.toId();
    }

    // ----- Helpers -----
    function _deployHook() internal returns (IHooks hook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG
            ) ^ (0x4242 << 144)
        );
        bytes memory constructorArgs = abi.encode(manager, dcaToken, developer, positionManagerV4);
        deployCodeTo("SuperDCAGauge.sol:SuperDCAGauge", constructorArgs, flags);
        return IHooks(flags);
    }

    function _initPoolWithHook(PoolKey memory _key, IHooks hook) internal returns (PoolKey memory) {
        _key.hooks = hook;
        manager.initialize(_key, SQRT_PRICE_1_1);
        return _key;
    }

    function _mockGetPoolAndPositionInfo(uint256 nfpId, PoolKey memory _key) internal {
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.getPoolAndPositionInfo.selector, nfpId),
            abi.encode(_key, bytes32(0))
        );
    }

    function _mockFullRangePosition(uint256 nfpId, int24 tickSpacing) internal {
        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.positionInfo.selector, nfpId),
            abi.encode(
                PositionInfo.wrap(
                    (uint256(uint24(uint256(int256(maxTick)))) << 32)
                        | (uint256(uint24(uint256(int256(minTick)))) << 8)
                )
            )
        );
    }

    function _mockNotFullRangePosition(uint256 nfpId) internal {
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.positionInfo.selector, nfpId),
            abi.encode(PositionInfo.wrap(uint256(bytes32(abi.encodePacked(int24(-60), int24(60))))))
        );
    }

    function _mockPartialRangeLowerWrong(uint256 nfpId, int24 tickSpacing) internal {
        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);
        int24 wrongLower = minTick + tickSpacing; // still aligned but not full-range
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.positionInfo.selector, nfpId),
            abi.encode(
                PositionInfo.wrap(
                    (uint256(uint24(uint256(int256(maxTick)))) << 32)
                        | (uint256(uint24(uint256(int256(wrongLower)))) << 8)
                )
            )
        );
    }

    function _mockPartialRangeUpperWrong(uint256 nfpId, int24 tickSpacing) internal {
        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);
        int24 wrongUpper = maxTick - tickSpacing; // still aligned but not full-range
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.positionInfo.selector, nfpId),
            abi.encode(
                PositionInfo.wrap(
                    (uint256(uint24(uint256(int256(wrongUpper)))) << 32)
                        | (uint256(uint24(uint256(int256(minTick)))) << 8)
                )
            )
        );
    }

    function _mockLiquidity(uint256 nfpId, uint128 liq) internal {
        vm.mockCall(
            address(posM), abi.encodeWithSelector(IPositionManager.getPositionLiquidity.selector, nfpId), abi.encode(liq)
        );
    }

    function _expectNfpTransfer(uint256 nfpId) internal {
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IERC721.transferFrom.selector, address(this), address(listing), nfpId),
            abi.encode(true)
        );
    }

    function _expectedNonDcaToken(PoolKey memory _key) internal view returns (address) {
        address c0 = Currency.unwrap(_key.currency0);
        address c1 = Currency.unwrap(_key.currency1);
        return c0 == address(dcaToken) ? c1 : c0;
    }
}

contract Constructor is SuperDCAListingTest {
    function test_SetsConfigurationParameters() public view {
        assertEq(address(listing.SUPER_DCA_TOKEN()), address(dcaToken));
        assertEq(address(listing.POOL_MANAGER()), address(manager));
        assertEq(address(listing.POSITION_MANAGER_V4()), address(positionManagerV4));
    }
}

contract SetHookAddress is SuperDCAListingTest {
    function test_SetsHookAddress_WhenCalledByAdmin() public {
        IHooks hook = _deployHook();
        vm.prank(developer);
        vm.expectEmit(true, true, true, true);
        emit SuperDCAListing.HookAddressSet(address(0), address(hook));
        listing.setHookAddress(hook);
    }

    function test_RevertWhen_SetHookAddressCalledByNonAdmin(address _notAdmin) public {
        vm.assume(_notAdmin != developer && _notAdmin != address(0));
        IHooks hook = _deployHook();
        vm.prank(_notAdmin);
        vm.expectRevert();
        listing.setHookAddress(hook);
    }
}

contract SetMinimumLiquidity is SuperDCAListingTest {
    function test_SetsMinimumLiquidity_WhenCalledByAdmin(uint256 _newMin) public {
        uint256 oldMin = listing.minLiquidity();
        vm.startPrank(developer);
        vm.expectEmit();
        emit SuperDCAListing.MinimumLiquidityUpdated(oldMin, _newMin);
        listing.setMinimumLiquidity(_newMin);
        vm.stopPrank();
        assertEq(listing.minLiquidity(), _newMin);
    }

    function test_RevertWhen_SetMinimumLiquidityCalledByNonAdmin(address _notAdmin, uint256 _newMin) public {
        vm.assume(_notAdmin != developer && _notAdmin != address(0));
        vm.prank(_notAdmin);
        vm.expectRevert();
        listing.setMinimumLiquidity(_newMin);
    }
}

contract List is SuperDCAListingTest {
    event TokenListed(address indexed token, uint256 indexed nftId, PoolKey key);
    event FeesCollected(
        address indexed recipient, address indexed token0, address indexed token1, uint256 amount0, uint256 amount1
    );

    function setUp() public override {
        super.setUp();
        IHooks hook = _deployHook();
        vm.prank(developer);
        listing.setHookAddress(hook);

        // assign hook to key and initialize pool
        key = _initPoolWithHook(key, hook);
    }

    function test_EmitsTokenListedAndRegistersToken_When_ValidFullRangeAndLiquidity() public {
        PoolKey memory keyWithDca = _createPoolKey(
            address(dcaToken), address(new MockERC20Token("ALT", "ALT", 18)), LPFeeLibrary.DYNAMIC_FEE_FLAG
        );
        keyWithDca = _initPoolWithHook(keyWithDca, key.hooks);

        uint256 nfpId = 123;
        _mockGetPoolAndPositionInfo(nfpId, keyWithDca);
        _mockFullRangePosition(nfpId, 60);
        _mockLiquidity(nfpId, uint128(2000 * 10 ** 18));
        _expectNfpTransfer(nfpId);

        address expectedToken = _expectedNonDcaToken(keyWithDca);
        vm.expectEmit(true, true, false, true);
        emit TokenListed(expectedToken, nfpId, keyWithDca);
        listing.list(nfpId, keyWithDca);

        assertTrue(listing.isTokenListed(expectedToken));
        assertEq(listing.tokenOfNfp(nfpId), expectedToken);
    }

    function test_RevertWhen_IncorrectHookAddress() public {
        PoolKey memory wrongHookKey = key;
        wrongHookKey.hooks = IHooks(address(0x1234));
        _mockGetPoolAndPositionInfo(1, wrongHookKey);
        vm.expectRevert(SuperDCAListing.IncorrectHookAddress.selector);
        listing.list(1, wrongHookKey);
    }

    function test_RevertWhen_NftIdIsZero() public {
        vm.expectRevert(SuperDCAListing.UniswapTokenNotSet.selector);
        listing.list(0, key);
    }

    function test_RevertWhen_FeeIsNotDynamic() public {
        PoolKey memory staticFeeKey = key;
        staticFeeKey.fee = 500; // not dynamic
        _mockGetPoolAndPositionInfo(1, staticFeeKey);
        vm.expectRevert(SuperDCAListing.NotDynamicFee.selector);
        listing.list(1, staticFeeKey);
    }

    function test_RevertWhen_PositionIsNotFullRange() public {
        uint256 nfpId = 456;
        _mockGetPoolAndPositionInfo(nfpId, key);
        _mockNotFullRangePosition(nfpId);
        vm.expectRevert(SuperDCAListing.NotFullRangePosition.selector);
        listing.list(nfpId, key);
    }

    function test_RevertWhen_PartialRange_LowerWrong() public {
        uint256 nfpId = 457;
        _mockGetPoolAndPositionInfo(nfpId, key);
        _mockPartialRangeLowerWrong(nfpId, 60);
        vm.expectRevert(SuperDCAListing.NotFullRangePosition.selector);
        listing.list(nfpId, key);
    }

    function test_RevertWhen_PartialRange_UpperWrong() public {
        uint256 nfpId = 458;
        _mockGetPoolAndPositionInfo(nfpId, key);
        _mockPartialRangeUpperWrong(nfpId, 60);
        vm.expectRevert(SuperDCAListing.NotFullRangePosition.selector);
        listing.list(nfpId, key);
    }

    function test_RevertWhen_PoolDoesNotIncludeDcaToken() public {
        PoolKey memory nonDcaKey = _createPoolKey(address(weth), address(0xBEEF), LPFeeLibrary.DYNAMIC_FEE_FLAG);
        nonDcaKey.hooks = key.hooks;
        _mockGetPoolAndPositionInfo(1, nonDcaKey);
        vm.expectRevert(SuperDCAListing.PoolMustIncludeSuperDCAToken.selector);
        listing.list(1, nonDcaKey);
    }

    function test_RevertWhen_LiquidityBelowMinimum() public {
        uint256 nfpId = 789;
        _mockGetPoolAndPositionInfo(nfpId, key);
        _mockFullRangePosition(nfpId, 60);
        _mockLiquidity(nfpId, uint128(500 * 10 ** 18));
        vm.expectRevert(SuperDCAListing.LowLiquidity.selector);
        listing.list(nfpId, key);
    }

    function test_RevertWhen_TokenAlreadyListed() public {
        uint256 id1 = 111;
        _mockGetPoolAndPositionInfo(id1, key);
        _mockFullRangePosition(id1, 60);
        _mockLiquidity(id1, uint128(2000 * 10 ** 18));
        _expectNfpTransfer(id1);
        listing.list(id1, key);

        uint256 id2 = 112;
        _mockGetPoolAndPositionInfo(id2, key);
        _mockFullRangePosition(id2, 60);
        _mockLiquidity(id2, uint128(2000 * 10 ** 18));
        _expectNfpTransfer(id2);
        vm.expectRevert(SuperDCAListing.TokenAlreadyListed.selector);
        listing.list(id2, key);
    }

    function test_RevertWhen_MismatchedPoolKeyProvided() public {
        uint256 nfpId = 4242;
        // actual key is the initialized one
        _mockGetPoolAndPositionInfo(nfpId, key);

        // provided key differs only in tickSpacing to trigger MismatchedPoolKey
        PoolKey memory provided = key;
        provided.tickSpacing = 30;
        vm.expectRevert(SuperDCAListing.MismatchedPoolKey.selector);
        listing.list(nfpId, provided);
    }
}

contract CollectFees is SuperDCAListingTest {
    event FeesCollected(
        address indexed recipient, address indexed token0, address indexed token1, uint256 amount0, uint256 amount1
    );

    function setUp() public override {
        super.setUp();
        IHooks hook = SuperDCAListingTest._deployHook();
        vm.prank(developer);
        listing.setHookAddress(hook);
        key = _initPoolWithHook(key, hook);
    }

    function test_EmitsFeesCollectedAndPerformsCollection_When_CalledByAdmin() public {
        // Arrange: mock pool info for NFP
        uint256 nfpId = 9999;
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.getPoolAndPositionInfo.selector, nfpId),
            abi.encode(key, bytes32(0))
        );

        address token0Addr = Currency.unwrap(key.currency0);
        address token1Addr = Currency.unwrap(key.currency1);
        address recipient = address(0x1234);

        // Seed balances
        deal(token0Addr, recipient, 1000e18);
        deal(token1Addr, recipient, 1000e18);

        // Mock PositionManager.modifyLiquidities call path using helper that transfers tokens
        new FeesCollectionMock(token0Addr, token1Addr, recipient, 10e18, 5e18);
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector),
            abi.encode(bytes4(0x43dc74a4))
        );

        // Act
        vm.prank(developer);
        vm.expectEmit(true, true, true, false);
        emit FeesCollected(recipient, token0Addr, token1Addr, 0, 0);
        listing.collectFees(nfpId, recipient);
    }

    function test_RevertWhen_CollectFeesCalledByNonAdmin(address _notAdmin) public {
        vm.assume(_notAdmin != developer && _notAdmin != address(0));
        vm.expectRevert();
        vm.prank(_notAdmin);
        listing.collectFees(1, address(0x1234));
    }

    function test_RevertWhen_CollectFeesWithZeroNfpId() public {
        vm.prank(developer);
        vm.expectRevert(SuperDCAListing.UniswapTokenNotSet.selector);
        listing.collectFees(0, address(0x1234));
    }

    function test_RevertWhen_CollectFeesWithZeroRecipient() public {
        vm.prank(developer);
        vm.expectRevert(SuperDCAListing.InvalidAddress.selector);
        listing.collectFees(1, address(0));
    }
}
