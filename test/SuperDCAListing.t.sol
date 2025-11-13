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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PositionManager} from "lib/v4-periphery/src/PositionManager.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPositionDescriptor} from "lib/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "lib/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Permit2Bytecode} from "test/utils/Permit2Bytecode.sol";
import {PositionInfo} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {Planner, Plan} from "lib/v4-periphery/test/shared/Planner.sol";
import {LiquidityAmounts as PeripheryLiquidityAmounts} from "lib/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SuperDCAGauge} from "src/SuperDCAGauge.sol";
import {FakeStaking} from "test/fakes/FakeStaking.sol";

import {MockERC20Token} from "./mocks/MockERC20Token.sol";
import {SuperDCAListing} from "../src/SuperDCAListing.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract SuperDCAListingTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // system
    MockERC20Token public dcaToken;
    MockERC20Token public weth;
    PositionManager public posM;
    IPositionManager public positionManagerV4;
    SuperDCAListing public listing;
    // Use Deployers.key inherited field
    PoolId poolId;

    IAllowanceTransfer public permit2;

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

        // PositionManager with etched local Permit2 runtime bytecode
        Deployers.deployMintAndApprove2Currencies();
        bytes memory p2code = new Permit2Bytecode().getBytecode();
        address p2addr = makeAddr("permit2");
        vm.etch(p2addr, p2code);
        permit2 = IAllowanceTransfer(p2addr);
        posM = new PositionManager(
            IPoolManager(address(manager)), permit2, 5000, IPositionDescriptor(address(0)), IWETH9(address(weth))
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
        // Set a no-op staking implementation to prevent hook reverts on add liquidity
        FakeStaking fake = new FakeStaking();
        vm.prank(developer);
        SuperDCAGauge(address(flags)).setStaking(address(fake));
        return IHooks(flags);
    }

    function _deployHookWithSalt(uint16 salt) internal returns (IHooks hook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG
            ) ^ (uint160(salt) << 144)
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

    // ----- New E2E helpers -----
    function _fundAndApprove(address owner, address token, uint256 amt) internal {
        deal(token, owner, amt);
        vm.prank(owner);
        IERC20(token).approve(address(permit2), type(uint256).max);
        vm.prank(owner);
        permit2.approve(token, address(posM), type(uint160).max, type(uint48).max);
    }

    function _liquidityForAmounts(PoolKey memory _key, uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint256 liq)
    {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(_key.toId());
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(_key.tickSpacing));
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(_key.tickSpacing));
        liq = PeripheryLiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtA, sqrtB, amount0, amount1);
    }

    function _mintFullRange(PoolKey memory _key, uint256 amount0, uint256 amount1, address owner)
        internal
        returns (uint256 nfpId)
    {
        // Fund and approve owner for both tokens via Permit2
        _fundAndApprove(owner, Currency.unwrap(_key.currency0), amount0);
        _fundAndApprove(owner, Currency.unwrap(_key.currency1), amount1);

        int24 lower = TickMath.minUsableTick(_key.tickSpacing);
        int24 upper = TickMath.maxUsableTick(_key.tickSpacing);
        uint256 liquidity = _liquidityForAmounts(_key, amount0, amount1);

        Plan memory planner = Planner.init();
        planner = planner.add(
            Actions.MINT_POSITION,
            abi.encode(_key, lower, upper, liquidity, type(uint128).max, type(uint128).max, owner, bytes(""))
        );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(_key);

        nfpId = positionManagerV4.nextTokenId();
        vm.prank(owner);
        positionManagerV4.modifyLiquidities(calls, block.timestamp);
    }

    function _mintNarrow(PoolKey memory _key, int24 lower, int24 upper, uint256 amount0, uint256 amount1, address owner)
        internal
        returns (uint256 nfpId)
    {
        _fundAndApprove(owner, Currency.unwrap(_key.currency0), amount0);
        _fundAndApprove(owner, Currency.unwrap(_key.currency1), amount1);

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(_key.toId());
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        uint256 liquidity =
            PeripheryLiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtA, sqrtB, amount0, amount1);

        Plan memory planner = Planner.init();
        planner = planner.add(
            Actions.MINT_POSITION,
            abi.encode(_key, lower, upper, liquidity, type(uint128).max, type(uint128).max, owner, bytes(""))
        );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(_key);

        nfpId = positionManagerV4.nextTokenId();
        vm.prank(owner);
        positionManagerV4.modifyLiquidities(calls, block.timestamp);
    }

    function _accrueFeesByDonation(PoolKey memory _key, uint256 amt0, uint256 amt1) internal {
        address t0 = Currency.unwrap(_key.currency0);
        address t1 = Currency.unwrap(_key.currency1);
        deal(t0, address(this), amt0);
        deal(t1, address(this), amt1);
        IERC20(t0).approve(address(donateRouter), amt0);
        IERC20(t1).approve(address(donateRouter), amt1);
        donateRouter.donate(_key, amt0, amt1, "");
    }

    function _mintFullRangeWithNativeETH(PoolKey memory _key, uint256 amount0, uint256 amount1, address owner)
        internal
        returns (uint256 nfpId)
    {
        // Fund and approve for non-native token only
        if (!_key.currency0.isAddressZero()) {
            _fundAndApprove(owner, Currency.unwrap(_key.currency0), amount0);
        } else {
            // Give owner ETH for native token
            vm.deal(owner, amount0 + 1 ether); // Extra for gas
        }

        if (!_key.currency1.isAddressZero()) {
            _fundAndApprove(owner, Currency.unwrap(_key.currency1), amount1);
        } else {
            // Give owner ETH for native token
            vm.deal(owner, amount1 + 1 ether); // Extra for gas
        }

        int24 lower = TickMath.minUsableTick(_key.tickSpacing);
        int24 upper = TickMath.maxUsableTick(_key.tickSpacing);
        uint256 liquidity = _liquidityForAmounts(_key, amount0, amount1);

        Plan memory planner = Planner.init();
        planner = planner.add(
            Actions.MINT_POSITION,
            abi.encode(_key, lower, upper, liquidity, type(uint128).max, type(uint128).max, owner, bytes(""))
        );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(_key);

        nfpId = positionManagerV4.nextTokenId();

        // Calculate ETH value to send
        uint256 ethValue = 0;
        if (_key.currency0.isAddressZero()) {
            ethValue = amount0;
        } else if (_key.currency1.isAddressZero()) {
            ethValue = amount1;
        }

        vm.prank(owner);
        positionManagerV4.modifyLiquidities{value: ethValue}(calls, block.timestamp);
    }

    function _accrueFeesByDonationWithNativeETH(PoolKey memory _key, uint256 amt0, uint256 amt1) internal {
        address t0 = Currency.unwrap(_key.currency0);
        address t1 = Currency.unwrap(_key.currency1);

        // Deal and approve non-native tokens
        if (!_key.currency0.isAddressZero()) {
            deal(t0, address(this), amt0);
            IERC20(t0).approve(address(donateRouter), amt0);
        } else {
            vm.deal(address(this), amt0 + 1 ether);
        }

        if (!_key.currency1.isAddressZero()) {
            deal(t1, address(this), amt1);
            IERC20(t1).approve(address(donateRouter), amt1);
        } else {
            vm.deal(address(this), amt1 + 1 ether);
        }

        // Calculate ETH value to send
        uint256 ethValue = 0;
        if (_key.currency0.isAddressZero()) {
            ethValue = amt0;
        } else if (_key.currency1.isAddressZero()) {
            ethValue = amt1;
        }

        donateRouter.donate{value: ethValue}(_key, amt0, amt1, "");
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
        assertEq(listing.owner(), developer);
    }

    function test_RevertWhen_InvalidSuperDCAToken() public {
        vm.expectRevert(SuperDCAListing.SuperDCAListing__ZeroAddress.selector);
        new SuperDCAListing(address(0), manager, positionManagerV4, developer, IHooks(address(0)));
    }

    function test_RevertWhen_InvalidAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new SuperDCAListing(address(dcaToken), manager, positionManagerV4, address(0), IHooks(address(0)));
    }
}

contract SetHookAddress is SuperDCAListingTest {
    function test_SetsHookAddress_WhenCalledByAdmin() public {
        IHooks hook = _deployHook();
        vm.prank(developer);
        vm.expectEmit();
        emit SuperDCAListing.HookAddressSet(address(0), address(hook));
        listing.setHookAddress(hook);
    }

    function test_RevertWhen_SetHookAddressCalledByNonAdmin(address _notAdmin) public {
        vm.assume(_notAdmin != developer && _notAdmin != address(0));
        IHooks hook = _deployHook();
        vm.prank(_notAdmin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _notAdmin));
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
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _notAdmin));
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

        // Set a no-op staking to prevent hook reverts on add liquidity
        FakeStaking fake = new FakeStaking();
        vm.prank(developer);
        SuperDCAGauge(address(hook)).setStaking(address(fake));

        // assign hook to key and initialize pool
        key = _initPoolWithHook(key, hook);

        // Transfer ownership to test contract for list tests
        vm.prank(developer);
        listing.transferOwnership(address(this));
        listing.acceptOwnership();
    }

    // Deterministically deploy a MockERC20Token at a specific address using deployCodeTo
    function _deployAltAt(address where) internal returns (MockERC20Token) {
        bytes memory args = abi.encode("ALT", "ALT", uint8(18));
        deployCodeTo("test/mocks/MockERC20Token.sol:MockERC20Token", args, where);
        return MockERC20Token(where);
    }

    function _addressGreaterThan(address ref) internal pure returns (address) {
        unchecked {
            return address(uint160(uint160(ref) + 1));
        }
    }

    function _addressLessThan(address ref) internal pure returns (address) {
        unchecked {
            return address(uint160(uint160(ref) - 1));
        }
    }

    function test_EmitsTokenListedAndRegistersToken_When_ValidFullRangeAndLiquidity() public {
        // Initialize a pool that includes the DCA token
        MockERC20Token alt = new MockERC20Token("ALT", "ALT", 18);
        PoolKey memory keyWithDca = _createPoolKey(address(dcaToken), address(alt), LPFeeLibrary.DYNAMIC_FEE_FLAG);
        keyWithDca = _initPoolWithHook(keyWithDca, key.hooks);

        // Mint a full-range NFP
        uint256 nfpId = _mintFullRange(keyWithDca, 2_000e18, 2_000e18, address(this));

        // Approve transfer to listing and list
        IERC721(address(positionManagerV4)).approve(address(listing), nfpId);
        address expectedToken = _expectedNonDcaToken(keyWithDca);
        vm.expectEmit(true, true, false, true);
        emit TokenListed(expectedToken, nfpId, keyWithDca);
        listing.list(nfpId);

        assertTrue(listing.isTokenListed(expectedToken));
        assertEq(listing.tokenOfNfp(nfpId), expectedToken);
        assertEq(IERC721(address(positionManagerV4)).ownerOf(nfpId), address(listing));
    }

    function test_RevertWhen_IncorrectHookAddress() public {
        // Initialize pool with one hook, but configure listing with a different expected hook
        IHooks hookB = _deployHookWithSalt(0x4243);
        // Test contract is the owner, so call directly
        listing.setHookAddress(hookB);

        // Use the already-initialized pool key with hookA
        PoolKey memory wrongHookKey = key;
        uint256 nfpId = _mintFullRange(wrongHookKey, 1_000e18, 1_000e18, address(this));
        IERC721(address(positionManagerV4)).approve(address(listing), nfpId);

        vm.expectRevert(SuperDCAListing.SuperDCAListing__IncorrectHookAddress.selector);
        listing.list(nfpId);
    }

    function test_RevertWhen_NftIdIsZero() public {
        vm.expectRevert(SuperDCAListing.SuperDCAListing__UniswapTokenNotSet.selector);
        listing.list(0);
    }

    function test_RevertWhen_PositionIsNotFullRange() public {
        int24 minTick = TickMath.minUsableTick(key.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(key.tickSpacing);
        uint256 nfpId = _mintNarrow(key, minTick + key.tickSpacing, maxTick, 1_000e18, 1_000e18, address(this));
        IERC721(address(positionManagerV4)).approve(address(listing), nfpId);
        vm.expectRevert(SuperDCAListing.SuperDCAListing__NotFullRangePosition.selector);
        listing.list(nfpId);
    }

    function test_RevertWhen_PartialRange_LowerWrong() public {
        int24 minTick = TickMath.minUsableTick(key.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(key.tickSpacing);
        uint256 nfpId = _mintNarrow(key, minTick + key.tickSpacing, maxTick, 1_000e18, 1_000e18, address(this));
        IERC721(address(positionManagerV4)).approve(address(listing), nfpId);
        vm.expectRevert(SuperDCAListing.SuperDCAListing__NotFullRangePosition.selector);
        listing.list(nfpId);
    }

    function test_RevertWhen_PartialRange_UpperWrong() public {
        int24 minTick = TickMath.minUsableTick(key.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(key.tickSpacing);
        uint256 nfpId = _mintNarrow(key, minTick, maxTick - key.tickSpacing, 1_000e18, 1_000e18, address(this));
        IERC721(address(positionManagerV4)).approve(address(listing), nfpId);
        vm.expectRevert(SuperDCAListing.SuperDCAListing__NotFullRangePosition.selector);
        listing.list(nfpId);
    }

    function test_RevertWhen_LiquidityBelowMinimum() public {
        // Mint tiny liquidity
        uint256 nfpId = _mintFullRange(key, 1e9, 1e9, address(this));
        IERC721(address(positionManagerV4)).approve(address(listing), nfpId);
        vm.expectRevert(SuperDCAListing.SuperDCAListing__LowLiquidity.selector);
        listing.list(nfpId);
    }

    function test_RevertWhen_TokenAlreadyListed() public {
        uint256 id1 = _mintFullRange(key, 2_000e18, 2_000e18, address(this));
        IERC721(address(positionManagerV4)).approve(address(listing), id1);
        listing.list(id1);

        uint256 id2 = _mintFullRange(key, 2_000e18, 2_000e18, address(this));
        IERC721(address(positionManagerV4)).approve(address(listing), id2);
        vm.expectRevert(SuperDCAListing.SuperDCAListing__TokenAlreadyListed.selector);
        listing.list(id2);
    }

    function test_RevertWhen_CallerIsNotOwner() public {
        // Create a new address that is not the owner
        address unauthorizedCaller = address(0x9999);

        // Mint a full-range NFP owned by the unauthorized caller
        uint256 nfpId = _mintFullRange(key, 2_000e18, 2_000e18, unauthorizedCaller);

        // Approve the listing contract to transfer the NFP and attempt to list
        vm.startPrank(unauthorizedCaller);
        IERC721(address(positionManagerV4)).approve(address(listing), nfpId);

        // Attempt to list without being the owner
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorizedCaller));
        listing.list(nfpId);
        vm.stopPrank();
    }

    function test_RegistersTokenAndTransfersNfp_When_DcaTokenIsCurrency0() public {
        // Ensure currency0 is the DCA token by deploying ALT at an address greater than DCA
        address altAddr = _addressGreaterThan(address(dcaToken));
        MockERC20Token alt = _deployAltAt(altAddr);
        PoolKey memory keyWithDca0 = _createPoolKey(address(dcaToken), address(alt), LPFeeLibrary.DYNAMIC_FEE_FLAG);
        keyWithDca0 = _initPoolWithHook(keyWithDca0, key.hooks);

        // Sanity: DCA must be currency0 for this branch
        assertEq(Currency.unwrap(keyWithDca0.currency0), address(dcaToken), "DCA not currency0");

        uint256 nfpId = _mintFullRange(keyWithDca0, 2_000e18, 2_000e18, address(this));
        IERC721(address(positionManagerV4)).approve(address(listing), nfpId);
        address expectedToken = _expectedNonDcaToken(keyWithDca0);

        listing.list(nfpId);

        assertTrue(listing.isTokenListed(expectedToken));
        assertEq(listing.tokenOfNfp(nfpId), expectedToken);
        assertEq(IERC721(address(positionManagerV4)).ownerOf(nfpId), address(listing));
    }

    function test_RegistersTokenAndTransfersNfp_When_DcaTokenIsCurrency1() public {
        // Ensure currency1 is the DCA token by deploying ALT at an address less than DCA
        address altAddr = _addressLessThan(address(dcaToken));
        MockERC20Token alt = _deployAltAt(altAddr);
        PoolKey memory keyWithDca1 = _createPoolKey(address(dcaToken), address(alt), LPFeeLibrary.DYNAMIC_FEE_FLAG);
        keyWithDca1 = _initPoolWithHook(keyWithDca1, key.hooks);

        // Sanity: DCA must be currency1 for this branch
        assertEq(Currency.unwrap(keyWithDca1.currency1), address(dcaToken), "DCA not currency1");

        uint256 nfpId = _mintFullRange(keyWithDca1, 2_000e18, 2_000e18, address(this));
        IERC721(address(positionManagerV4)).approve(address(listing), nfpId);
        address expectedToken = _expectedNonDcaToken(keyWithDca1);

        listing.list(nfpId);

        assertTrue(listing.isTokenListed(expectedToken));
        assertEq(listing.tokenOfNfp(nfpId), expectedToken);
        assertEq(IERC721(address(positionManagerV4)).ownerOf(nfpId), address(listing));
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

        // Set a no-op staking to prevent hook reverts on add liquidity
        FakeStaking fake = new FakeStaking();
        vm.prank(developer);
        SuperDCAGauge(address(hook)).setStaking(address(fake));
        key = _initPoolWithHook(key, hook);

        // Transfer ownership to test contract for list tests
        vm.prank(developer);
        listing.transferOwnership(address(this));
        listing.acceptOwnership();
    }

    function test_CollectFees_IncreasesRecipientBalances_When_CalledByAdmin() public {
        // Mint and list
        uint256 nfpId = _mintFullRange(key, 2_000e18, 2_000e18, address(this));
        IERC721(address(positionManagerV4)).approve(address(listing), nfpId);
        listing.list(nfpId);

        // Accrue fees via donation
        address token0Addr = Currency.unwrap(key.currency0);
        address token1Addr = Currency.unwrap(key.currency1);

        _accrueFeesByDonation(key, 100e18, 100e18);

        // Record recipient balances before collecting
        address recipient = address(0x1234);
        uint256 b0 = IERC20(token0Addr).balanceOf(recipient);
        uint256 b1 = IERC20(token1Addr).balanceOf(recipient);

        // Test contract is the owner, so call directly
        listing.collectFees(nfpId, recipient);

        assertGt(IERC20(token0Addr).balanceOf(recipient), b0);
        assertGt(IERC20(token1Addr).balanceOf(recipient), b1);
    }

    function test_EmitsFeesCollected_When_CalledByAdmin() public {
        // Mint and list
        uint256 nfpId = _mintFullRange(key, 2_000e18, 2_000e18, address(this));
        IERC721(address(positionManagerV4)).approve(address(listing), nfpId);
        listing.list(nfpId);

        // Accrue fees via donation to ensure non-zero collection
        uint256 expected0 = 100e18;
        uint256 expected1 = 100e18;
        _accrueFeesByDonation(key, expected0, expected1);

        address token0Addr = Currency.unwrap(key.currency0);
        address token1Addr = Currency.unwrap(key.currency1);
        address recipient = address(0xBEEF);

        // Expect the FeesCollected event with exact values
        vm.expectEmit();
        // 1 wei is lost due to precision in the donation/collection process (TAKE_PAIR action)
        emit FeesCollected(recipient, token0Addr, token1Addr, expected0 - 1, expected1 - 1);

        // Test contract is the owner, so call directly
        listing.collectFees(nfpId, recipient);
    }

    function test_RevertWhen_CollectFeesCalledByNonOwner(address _notOwner) public {
        vm.assume(_notOwner != address(this) && _notOwner != address(0));
        vm.prank(_notOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _notOwner));
        listing.collectFees(1, address(0x1234));
    }

    function test_RevertWhen_CollectFeesWithZeroNfpId() public {
        vm.expectRevert(SuperDCAListing.SuperDCAListing__UniswapTokenNotSet.selector);
        listing.collectFees(0, address(0x1234));
    }

    function test_RevertWhen_CollectFeesWithZeroRecipient() public {
        vm.expectRevert(SuperDCAListing.SuperDCAListing__InvalidAddress.selector);
        listing.collectFees(1, address(0));
    }

    /// @dev Test that collectFees works with native ETH (address(0)) as token0
    /// Native ETH can only be currency0 since address(0) is the minimum address
    function test_CollectFees_WorksWithNativeETHAsToken0() public {
        // Create a pool key with native ETH as token0
        // Native ETH (address(0)) must be currency0 since address(0) < any other address
        PoolKey memory nativeKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(dcaToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Deploy and set hook for native pool
        IHooks hook = _deployHook();
        nativeKey = _initPoolWithHook(nativeKey, hook);
        // Test contract is the owner, so call directly
        listing.setHookAddress(hook);

        // Mint position with native ETH and list
        address owner = address(this);
        uint256 nfpId = _mintFullRangeWithNativeETH(nativeKey, 2_000e18, 2_000e18, owner);

        IERC721(address(positionManagerV4)).approve(address(listing), nfpId);
        listing.list(nfpId);

        // Accrue fees via donation
        _accrueFeesByDonationWithNativeETH(nativeKey, 0.1 ether, 100e18);

        // Record recipient balances before collecting
        address recipient = address(0x1234);
        uint256 ethBalanceBefore = recipient.balance;
        uint256 tokenBalanceBefore = dcaToken.balanceOf(recipient);

        // Test contract is the owner, so call directly
        listing.collectFees(nfpId, recipient);

        // Verify balances increased (fees collected successfully)
        assertGt(recipient.balance, ethBalanceBefore, "Native ETH fees should be collected");
        assertGt(dcaToken.balanceOf(recipient), tokenBalanceBefore, "DCA token fees should be collected");
    }

    /// @dev Test that collectFees emits correct event with native ETH
    function test_EmitsFeesCollected_WithNativeETH() public {
        // Create a pool key with native ETH as token0
        PoolKey memory nativeKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(dcaToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Deploy and set hook for native pool
        IHooks hook = _deployHook();
        nativeKey = _initPoolWithHook(nativeKey, hook);
        // Test contract is the owner, so call directly
        listing.setHookAddress(hook);

        // Mint position with native ETH and list
        address owner = address(this);
        uint256 nfpId = _mintFullRangeWithNativeETH(nativeKey, 2_000e18, 2_000e18, owner);

        IERC721(address(positionManagerV4)).approve(address(listing), nfpId);
        listing.list(nfpId);

        // Accrue fees via donation
        uint256 expectedETH = 0.1 ether;
        uint256 expectedToken = 100e18;
        _accrueFeesByDonationWithNativeETH(nativeKey, expectedETH, expectedToken);

        address recipient = address(0xBEEF);

        // Expect the FeesCollected event with native ETH (address(0))
        vm.expectEmit();
        // 1 wei is lost due to precision in the donation/collection process
        emit FeesCollected(recipient, address(0), address(dcaToken), expectedETH - 1, expectedToken - 1);

        // Test contract is the owner, so call directly
        listing.collectFees(nfpId, recipient);
    }
}
