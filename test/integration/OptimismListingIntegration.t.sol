// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {OptimismIntegrationBase} from "./OptimismIntegrationBase.t.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SuperDCAListing} from "../../src/SuperDCAListing.sol";
import {MockERC20Token} from "../mocks/MockERC20Token.sol";

/// @notice Integration tests for SuperDCAListing on Optimism mainnet fork
contract OptimismListingIntegration is OptimismIntegrationBase {
    using PoolIdLibrary for PoolKey;

    /// @notice Test successful token listing with valid full-range position
    function testFork_ListToken_Success() public {
        // ---- Arrange ----
        uint160 sqrtPriceX96 = _getCurrentPrice();
        (PoolKey memory key,) = _createTestPool(WETH, int24(60), sqrtPriceX96);

        uint256 nftId = _createFullRangePosition(key, POSITION_AMOUNT0, POSITION_AMOUNT1, address(this));

        // Verify we own the NFT
        assertEq(IERC721(POSITION_MANAGER_V4).ownerOf(nftId), address(this));

        // ---- Act ----
        IERC721(POSITION_MANAGER_V4).approve(address(listing), nftId);
        listing.list(nftId, key);

        // ---- Assert ----
        _assertTokenListed(WETH, nftId);
        assertEq(IERC721(POSITION_MANAGER_V4).ownerOf(nftId), address(listing), "Listing should own NFT");
    }

    /// @notice Test listing fails with insufficient liquidity
    function testFork_ListToken_InsufficientLiquidity() public {
        // ---- Arrange ----
        uint160 sqrtPriceX96 = _getCurrentPrice();
        (PoolKey memory key,) = _createTestPool(WETH, int24(60), sqrtPriceX96);

        // Create a position with insufficient DCA liquidity
        uint256 dcaAmount = 500e18; // Below minimum liquidity (1000e18)
        uint256 wethAmount = 1e18;

        uint256 nftId = _createFullRangePosition(key, wethAmount, dcaAmount, address(this));

        // ---- Act & Assert ----
        IERC721(POSITION_MANAGER_V4).approve(address(listing), nftId);

        vm.expectRevert(abi.encodeWithSignature("SuperDCAListing__LowLiquidity()"));
        listing.list(nftId, key);
    }

    /// @notice Test listing fails with incorrect hook address
    function testFork_ListToken_IncorrectHook() public {
        // ---- Arrange ----
        // Create a valid V4 hook address with some permissions but different from our gauge
        // This address has the BEFORE_SWAP_FLAG (bit 7) set: 0x80 = 128 = 1000 0000 in binary
        // Address format: 0x...80 (last byte has bit 7 set for beforeSwap permission)
        address wrongHookAddress = address(uint160(0x1000000000000000000000000000000000000080));

        PoolKey memory wrongKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(DCA_TOKEN),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(60),
            hooks: IHooks(wrongHookAddress) // Valid V4 hook address but wrong for our system
        });

        // initialize the pool
        _createTestPoolFromKey(wrongKey, _getCurrentPrice());
        uint256 nftId = _createFullRangePosition(wrongKey, POSITION_AMOUNT0, POSITION_AMOUNT1, address(this));

        // ---- Act & Assert ----
        vm.expectRevert(abi.encodeWithSignature("SuperDCAListing__IncorrectHookAddress()"));
        listing.list(nftId, wrongKey); // Will fail during validation
    }

    /// @notice Test listing fails for already listed token
    function testFork_ListToken_AlreadyListed() public {
        // ---- Arrange ----
        uint160 sqrtPriceX96 = _getCurrentPrice();
        (PoolKey memory key,) = _createTestPool(WETH, int24(60), sqrtPriceX96);

        // Create and list first position
        uint256 nftId1 = _createFullRangePosition(key, POSITION_AMOUNT0, POSITION_AMOUNT1, address(this));

        IERC721(POSITION_MANAGER_V4).approve(address(listing), nftId1);
        listing.list(nftId1, key);

        // Create second position for same token
        uint256 nftId2 = _createFullRangePosition(key, POSITION_AMOUNT0, POSITION_AMOUNT1, address(this));

        // ---- Act & Assert ----
        IERC721(POSITION_MANAGER_V4).approve(address(listing), nftId2);

        vm.expectRevert(abi.encodeWithSignature("SuperDCAListing__TokenAlreadyListed()"));
        listing.list(nftId2, key);
    }

    /// @notice Test minimum liquidity update by owner
    function testFork_SetMinimumLiquidity_Success() public {
        // ---- Arrange ----
        uint256 oldMinLiquidity = listing.minLiquidity();
        uint256 newMinLiquidity = 5000e18;

        // ---- Act ----
        vm.expectEmit();
        emit SuperDCAListing.MinimumLiquidityUpdated(oldMinLiquidity, newMinLiquidity);
        listing.setMinimumLiquidity(newMinLiquidity);

        // ---- Assert ----
        assertEq(listing.minLiquidity(), newMinLiquidity, "Minimum liquidity should be updated");
    }

    /// @notice Test minimum liquidity update fails for non-owner
    function testFork_SetMinimumLiquidity_NotOwner() public {
        // ---- Arrange ----
        uint256 newMinLiquidity = 5000e18;

        // ---- Act & Assert ----
        vm.prank(user1);
        vm.expectRevert(); // OwnableUnauthorizedAccount error
        listing.setMinimumLiquidity(newMinLiquidity);
    }

    /// @notice Test hook address update by owner
    function testFork_SetHookAddress_Success() public {
        // ---- Arrange ----
        address oldHook = address(listing.expectedHooks());
        address newHook = address(0x5678);

        // ---- Act ----
        vm.expectEmit();
        emit SuperDCAListing.HookAddressSet(oldHook, newHook);
        listing.setHookAddress(IHooks(newHook));

        // ---- Assert ----
        assertEq(address(listing.expectedHooks()), newHook, "Hook address should be updated");
    }

    /// @notice Test hook address update fails for non-owner
    function testFork_SetHookAddress_NotOwner() public {
        // ---- Arrange ----
        address newHook = address(0x5678);

        // ---- Act & Assert ----
        vm.prank(user1);
        vm.expectRevert(); // OwnableUnauthorizedAccount error
        listing.setHookAddress(IHooks(newHook));
    }

    /// @notice Test fee collection functionality
    function testFork_CollectFees_Success() public {
        // ---- Arrange ----
        uint160 sqrtPriceX96 = _getCurrentPrice();
        (PoolKey memory key,) = _createTestPool(WETH, int24(60), sqrtPriceX96);

        // Create and list position
        uint256 nftId = _createFullRangePosition(key, POSITION_AMOUNT0, POSITION_AMOUNT1, address(this));

        IERC721(POSITION_MANAGER_V4).approve(address(listing), nftId);
        listing.list(nftId, key);

        // Simulate some fees accumulation by time passing and trading activity
        _simulateTimePass(3600); // 1 hour

        address feeRecipient = makeAddr("feeRecipient");
        uint256 dcaBalanceBefore = IERC20(DCA_TOKEN).balanceOf(feeRecipient);
        uint256 wethBalanceBefore = IERC20(WETH).balanceOf(feeRecipient);

        // ---- Act ----
        listing.collectFees(nftId, feeRecipient);

        // ---- Assert ----
        uint256 dcaBalanceAfter = IERC20(DCA_TOKEN).balanceOf(feeRecipient);
        uint256 wethBalanceAfter = IERC20(WETH).balanceOf(feeRecipient);

        // Note: In a real fork test, there might be actual fees to collect
        // Here we're mainly testing the function doesn't revert
        assertGe(dcaBalanceAfter, dcaBalanceBefore, "DCA balance should not decrease");
        assertGe(wethBalanceAfter, wethBalanceBefore, "WETH balance should not decrease");
    }

    /// @notice Test fee collection fails for non-owner
    function testFork_CollectFees_NotOwner() public {
        // ---- Arrange ----
        uint256 nftId = 1;
        address feeRecipient = makeAddr("feeRecipient");

        // ---- Act & Assert ----
        vm.prank(user1);
        vm.expectRevert(); // OwnableUnauthorizedAccount error
        listing.collectFees(nftId, feeRecipient);
    }

    /// @notice Test fee collection fails with zero NFT ID
    function testFork_CollectFees_ZeroNftId() public {
        // ---- Arrange ----
        uint256 nftId = 0;
        address feeRecipient = makeAddr("feeRecipient");

        // ---- Act & Assert ----
        vm.expectRevert(abi.encodeWithSignature("SuperDCAListing__UniswapTokenNotSet()"));
        listing.collectFees(nftId, feeRecipient);
    }

    /// @notice Test fee collection fails with zero recipient
    function testFork_CollectFees_ZeroRecipient() public {
        // ---- Arrange ----
        uint256 nftId = 1;
        address feeRecipient = address(0);

        // ---- Act & Assert ----
        vm.expectRevert(abi.encodeWithSignature("SuperDCAListing__InvalidAddress()"));
        listing.collectFees(nftId, feeRecipient);
    }

    /// @notice Test multiple token listings work correctly
    function testFork_MultipleTokenListings() public {
        // ---- Arrange ----
        uint160 sqrtPriceX96 = _getCurrentPrice();

        // Create WETH pool
        (PoolKey memory wethKey,) = _createTestPool(WETH, int24(60), sqrtPriceX96);
        uint256 wethNftId = _createFullRangePosition(wethKey, POSITION_AMOUNT0, POSITION_AMOUNT1, address(this));

        // Deploy a proper mock ERC20 for second token
        MockERC20Token mockToken = new MockERC20Token("Mock Token", "MOCK", 18);
        address mockTokenAddress = address(mockToken);

        // Mint tokens to test contract
        mockToken.mint(address(this), 10000e18);

        // Create mock token pool
        (PoolKey memory mockKey,) = _createTestPool(mockTokenAddress, int24(60), sqrtPriceX96);
        uint256 mockNftId = _createFullRangePosition(mockKey, 100e18, 2000e18, address(this));

        // ---- Act ----
        // List WETH
        IERC721(POSITION_MANAGER_V4).approve(address(listing), wethNftId);
        listing.list(wethNftId, wethKey);

        // List mock token
        IERC721(POSITION_MANAGER_V4).approve(address(listing), mockNftId);
        listing.list(mockNftId, mockKey);

        // ---- Assert ----
        _assertTokenListed(WETH, wethNftId);
        _assertTokenListed(mockTokenAddress, mockNftId);
    }
}
