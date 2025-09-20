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

    function _createPoolKey(address tokenA, address tokenB, uint24 fee) internal view returns (PoolKey memory k) {
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
}

contract ListBehavior is SuperDCAListingTest {
    event TokenListed(address indexed token, uint256 indexed nftId, PoolKey key);
    event FeesCollected(
        address indexed recipient, address indexed token0, address indexed token1, uint256 amount0, uint256 amount1
    );

    function setUp() public override {
        super.setUp();
        // Deploy a valid hook contract (SuperDCAGauge) to a flagged address, as required by V4
        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG
            ) ^ (0x4242 << 144)
        );
        bytes memory constructorArgs = abi.encode(manager, dcaToken, developer, positionManagerV4);
        deployCodeTo("SuperDCAGauge.sol:SuperDCAGauge", constructorArgs, flags);

        IHooks hook = IHooks(flags);
        vm.prank(developer);
        listing.setHookAddress(hook);

        // assign hook to key and initialize pool
        key.hooks = hook;
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_list_success_dcaTokenAsToken0() public {
        // Build key where dca is one of tokens; ordering by address may place it as token1
        PoolKey memory keyWithDcaAsToken0 = _createPoolKey(
            address(dcaToken), address(new MockERC20Token("ALT", "ALT", 18)), LPFeeLibrary.DYNAMIC_FEE_FLAG
        );
        keyWithDcaAsToken0.hooks = key.hooks;
        manager.initialize(keyWithDcaAsToken0, SQRT_PRICE_1_1);

        uint256 nfpId = 123;

        // full range position
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.positionInfo.selector, nfpId),
            abi.encode(
                PositionInfo.wrap(
                    (uint256(uint24(uint256(int256(TickMath.maxUsableTick(60))))) << 32)
                        | (uint256(uint24(uint256(int256(TickMath.minUsableTick(60))))) << 8)
                )
            )
        );

        // liquidity above minimum
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.getPositionLiquidity.selector, nfpId),
            abi.encode(uint128(2000 * 10 ** 18))
        );
        // transferFrom succeeds
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IERC721.transferFrom.selector, address(this), address(listing), nfpId),
            abi.encode(true)
        );

        // Determine expected non-DCA token for the event regardless of ordering
        address expectedToken = Currency.unwrap(keyWithDcaAsToken0.currency0) == address(dcaToken)
            ? Currency.unwrap(keyWithDcaAsToken0.currency1)
            : Currency.unwrap(keyWithDcaAsToken0.currency0);
        vm.expectEmit(true, true, false, true);
        emit TokenListed(expectedToken, nfpId, keyWithDcaAsToken0);
        listing.list(nfpId, keyWithDcaAsToken0);

        assertTrue(listing.isTokenListed(expectedToken));
        assertEq(listing.tokenOfNfp(nfpId), expectedToken);
    }

    function test_list_revert_incorrectHookAddress() public {
        PoolKey memory wrongHookKey = key;
        wrongHookKey.hooks = IHooks(address(0x1234));
        vm.expectRevert(SuperDCAListing.IncorrectHookAddress.selector);
        listing.list(1, wrongHookKey);
    }

    function test_list_revert_zeroNftId() public {
        vm.expectRevert(SuperDCAListing.UniswapTokenNotSet.selector);
        listing.list(0, key);
    }

    function test_list_revert_notDynamicFee() public {
        PoolKey memory staticFeeKey = key;
        staticFeeKey.fee = 500; // not dynamic
        vm.expectRevert(SuperDCAListing.NotDynamicFee.selector);
        listing.list(1, staticFeeKey);
    }

    function test_list_revert_notFullRangePosition() public {
        uint256 nfpId = 456;
        // not full range ticks
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.positionInfo.selector, nfpId),
            abi.encode(PositionInfo.wrap(uint256(bytes32(abi.encodePacked(int24(-60), int24(60))))))
        );
        vm.expectRevert(SuperDCAListing.NotFullRangePosition.selector);
        listing.list(nfpId, key);
    }

    function test_list_revert_poolMustIncludeSuperDCAToken() public {
        PoolKey memory nonDcaKey = _createPoolKey(address(weth), address(0xBEEF), LPFeeLibrary.DYNAMIC_FEE_FLAG);
        nonDcaKey.hooks = key.hooks;
        vm.expectRevert(SuperDCAListing.PoolMustIncludeSuperDCAToken.selector);
        listing.list(1, nonDcaKey);
    }

    function test_list_revert_lowLiquidity() public {
        uint256 nfpId = 789;
        // full range ticks
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.positionInfo.selector, nfpId),
            abi.encode(
                PositionInfo.wrap(
                    (uint256(uint24(uint256(int256(TickMath.maxUsableTick(60))))) << 32)
                        | (uint256(uint24(uint256(int256(TickMath.minUsableTick(60))))) << 8)
                )
            )
        );
        // below min
        vm.mockCall(
            address(posM),
            abi.encodeWithSelector(IPositionManager.getPositionLiquidity.selector, nfpId),
            abi.encode(uint128(500 * 10 ** 18))
        );
        vm.expectRevert(SuperDCAListing.LowLiquidity.selector);
        listing.list(nfpId, key);
    }

    function test_collect_fees_success() public {
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
        FeesCollectionMock helper = new FeesCollectionMock(token0Addr, token1Addr, recipient, 10e18, 5e18);
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
}
