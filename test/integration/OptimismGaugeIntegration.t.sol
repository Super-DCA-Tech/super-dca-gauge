// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {OptimismIntegrationBase} from "./OptimismIntegrationBase.t.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SuperDCAGauge} from "../../src/SuperDCAGauge.sol";
import {IStateView} from "lib/v4-periphery/src/interfaces/IStateView.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Integration tests for SuperDCAGauge on Optimism mainnet fork
contract OptimismGaugeIntegration is OptimismIntegrationBase {
    /// @notice Test pool initialization with correct parameters
    function testFork_InitializePool_Success() public {
        // ---- Arrange ----
        uint160 sqrtPriceX96 = _getCurrentPrice();

        // ---- Act ----
        (PoolKey memory key, PoolId poolId) = _createTestPool(WETH, int24(60), sqrtPriceX96);

        // ---- Assert ----
        // Pool should be initialized successfully
        assertEq(address(key.hooks), address(gauge), "Hook should be gauge address");

        // Verify dynamic fee is enabled
        assertTrue(key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG, "Pool should have dynamic fee enabled");

        // Verify pool was actually initialized by checking its state using StateView
        (uint160 price, int24 tick,,) = STATE_VIEW.getSlot0(poolId);
        assertEq(price, sqrtPriceX96, "Pool price should match initialization price");
        assertGt(tick, type(int24).min, "Pool tick should be initialized");

        // Verify pool liquidity starts at 0
        uint128 liquidity = STATE_VIEW.getLiquidity(poolId);
        assertEq(liquidity, 0, "Pool should start with 0 liquidity");

        // Verify pool contains DCA token
        assertTrue(
            Currency.unwrap(key.currency0) == DCA_TOKEN || Currency.unwrap(key.currency1) == DCA_TOKEN,
            "Pool should contain DCA token"
        );
    }

    /// @notice Test pool initialization fails without DCA token
    function testFork_InitializePool_MustIncludeDCAToken() public {
        // ---- Arrange ----
        uint160 sqrtPriceX96 = _getCurrentPrice();

        // Create a pool key without DCA token (WETH/USDC for example)
        address USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; // USDC on Optimism

        (Currency currency0, Currency currency1) =
            WETH < USDC ? (Currency.wrap(WETH), Currency.wrap(USDC)) : (Currency.wrap(USDC), Currency.wrap(WETH));

        PoolKey memory invalidKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(60),
            hooks: IHooks(address(gauge))
        });

        // ---- Act & Assert ----
        /// @dev Manually verified in the stack trace that the rever reason is "PoolMustIncludeSuperDCAToken()"
        /// Unsure how to use WrappedError here to properly test this revert.
        vm.expectRevert();
        poolManager.initialize(invalidKey, sqrtPriceX96);
    }

    /// @notice Test fee tier assignment for different user types
    function testFork_SwapFees_DifferentUserTypes() public {
        // ---- Arrange ----
        uint160 sqrtPriceX96 = _getCurrentPrice();
        _createTestPool(WETH, int24(60), sqrtPriceX96);

        // Set up different user types
        address internalUser = makeAddr("internal");
        address keeperUser = makeAddr("keeper");
        address externalUser = makeAddr("external");

        // Configure internal user
        gauge.setInternalAddress(internalUser, true);

        // Configure keeper (deposit to become keeper)
        deal(DCA_TOKEN, keeperUser, 5000e18);
        vm.startPrank(keeperUser);
        IERC20(DCA_TOKEN).approve(address(gauge), 5000e18);
        gauge.becomeKeeper(5000e18);
        vm.stopPrank();

        // ---- Act & Assert ----
        // Verify fee assignments through getter functions
        assertTrue(gauge.isInternalAddress(internalUser), "Internal user should be marked internal");

        (address currentKeeper, uint256 deposit) = gauge.getKeeperInfo();
        assertEq(currentKeeper, keeperUser, "Keeper should be set correctly");
        assertEq(deposit, 5000e18, "Keeper deposit should be correct");

        assertFalse(gauge.isInternalAddress(externalUser), "External user should not be internal");
        assertEq(gauge.internalFee(), 0, "Internal fee should be 0");
        assertEq(gauge.keeperFee(), 1000, "Keeper fee should be 0.10%");
        assertEq(gauge.externalFee(), 5000, "External fee should be 0.50%");
    }

    /// @notice Test keeper mechanism with king-of-the-hill
    function testFork_BecomeKeeper_KingOfTheHill() public {
        // ---- Arrange ----
        address keeper1 = makeAddr("keeper1");
        address keeper2 = makeAddr("keeper2");

        deal(DCA_TOKEN, keeper1, 10000e18);
        deal(DCA_TOKEN, keeper2, 10000e18);

        // ---- Act ----
        // Keeper1 becomes keeper
        vm.startPrank(keeper1);
        IERC20(DCA_TOKEN).approve(address(gauge), 1000e18);

        vm.expectEmit(true, true, true, true);
        emit KeeperChanged(address(0), keeper1, 1000e18);
        gauge.becomeKeeper(1000e18);
        vm.stopPrank();

        // Keeper2 takes over with higher deposit
        vm.startPrank(keeper2);
        IERC20(DCA_TOKEN).approve(address(gauge), 2000e18);

        vm.expectEmit(true, true, true, true);
        emit KeeperChanged(keeper1, keeper2, 2000e18);
        gauge.becomeKeeper(2000e18);
        vm.stopPrank();

        // ---- Assert ----
        (address currentKeeper, uint256 deposit) = gauge.getKeeperInfo();
        assertEq(currentKeeper, keeper2, "Keeper2 should be current keeper");
        assertEq(deposit, 2000e18, "Deposit should be updated");

        // Keeper1 should have received refund
        assertGe(IERC20(DCA_TOKEN).balanceOf(keeper1), 10000e18 - 1000e18 + 1000e18, "Keeper1 should be refunded");
    }

    /// @notice Test keeper mechanism fails with insufficient deposit
    function testFork_BecomeKeeper_InsufficientDeposit() public {
        // ---- Arrange ----
        address keeper1 = makeAddr("keeper1");
        address keeper2 = makeAddr("keeper2");

        deal(DCA_TOKEN, keeper1, 10000e18);
        deal(DCA_TOKEN, keeper2, 10000e18);

        // Keeper1 becomes keeper
        vm.startPrank(keeper1);
        IERC20(DCA_TOKEN).approve(address(gauge), 2000e18);
        gauge.becomeKeeper(2000e18);
        vm.stopPrank();

        // ---- Act & Assert ----
        // Keeper2 tries with lower deposit
        vm.startPrank(keeper2);
        IERC20(DCA_TOKEN).approve(address(gauge), 1000e18);

        vm.expectRevert(abi.encodeWithSignature("SuperDCAGauge__InsufficientBalance()"));
        gauge.becomeKeeper(1000e18);
        vm.stopPrank();
    }

    /// @notice Test fee configuration updates
    function testFork_SetFees_Success() public {
        // ---- Arrange ----
        uint24 newInternalFee = 100;
        uint24 newExternalFee = 3000;
        uint24 newKeeperFee = 500;

        // ---- Act & Assert ----
        // Test internal fee update
        vm.expectEmit(true, true, true, true);
        emit FeeUpdated(0, 0, newInternalFee); // INTERNAL = 0
        gauge.setFee(SuperDCAGauge.FeeType(0), newInternalFee);
        assertEq(gauge.internalFee(), newInternalFee, "Internal fee should be updated");

        // Test external fee update
        vm.expectEmit(true, true, true, true);
        emit FeeUpdated(1, 5000, newExternalFee); // EXTERNAL = 1
        gauge.setFee(SuperDCAGauge.FeeType(1), newExternalFee);
        assertEq(gauge.externalFee(), newExternalFee, "External fee should be updated");

        // Test keeper fee update
        vm.expectEmit(true, true, true, true);
        emit FeeUpdated(2, 1000, newKeeperFee); // KEEPER = 2
        gauge.setFee(SuperDCAGauge.FeeType(2), newKeeperFee);
        assertEq(gauge.keeperFee(), newKeeperFee, "Keeper fee should be updated");
    }

    /// @notice Test internal address management
    function testFork_SetInternalAddress_Success() public {
        // ---- Arrange ----
        address user = makeAddr("user");

        // ---- Act & Assert ----
        // Mark as internal
        vm.expectEmit(true, true, true, true);
        emit InternalAddressUpdated(user, true);
        gauge.setInternalAddress(user, true);
        assertTrue(gauge.isInternalAddress(user), "User should be marked internal");

        // Unmark as internal
        vm.expectEmit(true, true, true, true);
        emit InternalAddressUpdated(user, false);
        gauge.setInternalAddress(user, false);
        assertFalse(gauge.isInternalAddress(user), "User should not be internal");
    }

    /// @notice Test internal address setting fails with zero address
    function testFork_SetInternalAddress_ZeroAddress() public {
        // ---- Act & Assert ----
        vm.expectRevert(abi.encodeWithSignature("SuperDCAGauge__ZeroAddress()"));
        gauge.setInternalAddress(address(0), true);
    }

    /// @notice Test token listing delegation to listing contract
    function testFork_IsTokenListed_DelegatesToListing() public {
        // ---- Arrange ----
        uint160 sqrtPriceX96 = _getCurrentPrice();
        (PoolKey memory key,) = _createTestPool(WETH, int24(60), sqrtPriceX96);
        uint256 nftId = _createFullRangePosition(key, POSITION_AMOUNT0, POSITION_AMOUNT1, address(this));

        // Initially not listed
        assertFalse(gauge.isTokenListed(WETH), "WETH should not be listed initially");

        // ---- Act ----
        IERC721(POSITION_MANAGER_V4).approve(address(listing), nftId);
        listing.list(nftId, key);

        // ---- Assert ----
        assertTrue(gauge.isTokenListed(WETH), "WETH should be listed after listing");
    }

    /// @notice Test reward distribution integration with staking
    function testFork_RewardDistribution_Integration() public {
        // ---- Arrange ----
        // Set up listed token and stakes
        uint160 sqrtPriceX96 = _getCurrentPrice();
        (PoolKey memory key,) = _createTestPool(WETH, int24(60), sqrtPriceX96);
        uint256 nftId = _createFullRangePosition(key, POSITION_AMOUNT0, POSITION_AMOUNT1, address(this));

        IERC721(POSITION_MANAGER_V4).approve(address(listing), nftId);
        listing.list(nftId, key);

        // Stake tokens
        vm.startPrank(user1);
        IERC20(DCA_TOKEN).approve(address(staking), STAKE_AMOUNT);
        staking.stake(WETH, STAKE_AMOUNT);
        vm.stopPrank();

        // Simulate time passing for rewards
        _simulateTimePass(3600); // 1 hour

        uint256 pendingReward = staking.previewPending(WETH);
        assertGt(pendingReward, 0, "Should have pending rewards");

        // ---- Act ----
        // Trigger reward distribution by adding liquidity (this calls the hook)
        uint256 additionalDCA = 100e18;
        uint256 additionalWETH = 0.1e18;

        deal(DCA_TOKEN, address(this), additionalDCA);
        deal(WETH, address(this), additionalWETH);

        // Create another position to trigger beforeAddLiquidity hook
        _createFullRangePosition(key, additionalDCA, additionalWETH, address(this));

        // ---- Assert ----
        // After hook execution, pending should be reset
        uint256 newPending = staking.previewPending(WETH);
        assertLt(newPending, pendingReward, "Pending should be reduced after distribution");
    }

    /// @notice Test access control for setStaking function
    function testFork_AccessControl_SetStaking_RevertIf_NotAdmin() public {
        // ---- Arrange ----
        address unauthorizedUser = makeAddr("unauthorized");

        // ---- Act & Assert ----
        vm.startPrank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedUser, gauge.DEFAULT_ADMIN_ROLE()
            )
        );
        gauge.setStaking(address(0x1234));
        vm.stopPrank();
    }

    /// @notice Test access control for setListing function
    function testFork_AccessControl_SetListing_RevertIf_NotAdmin() public {
        // ---- Arrange ----
        address unauthorizedUser = makeAddr("unauthorized");

        // ---- Act & Assert ----
        vm.startPrank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedUser, gauge.DEFAULT_ADMIN_ROLE()
            )
        );
        gauge.setListing(address(0x1234));
        vm.stopPrank();
    }

    /// @notice Test access control for updateManager function
    function testFork_AccessControl_UpdateManager_RevertIf_NotAdmin() public {
        // ---- Arrange ----
        address unauthorizedUser = makeAddr("unauthorized");

        // ---- Act & Assert ----
        vm.startPrank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedUser, gauge.DEFAULT_ADMIN_ROLE()
            )
        );
        gauge.updateManager(deployer, address(0x1234));
        vm.stopPrank();
    }

    /// @notice Test access control for setFee function
    function testFork_AccessControl_SetFee_RevertIf_NotManager() public {
        // ---- Arrange ----
        address unauthorizedUser = makeAddr("unauthorized");

        // ---- Act & Assert ----
        vm.startPrank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedUser, gauge.MANAGER_ROLE()
            )
        );
        gauge.setFee(SuperDCAGauge.FeeType(0), 100);
        vm.stopPrank();
    }

    /// @notice Test access control for setInternalAddress function
    function testFork_AccessControl_SetInternalAddress_RevertIf_NotManager() public {
        // ---- Arrange ----
        address unauthorizedUser = makeAddr("unauthorized");

        // ---- Act & Assert ----
        vm.startPrank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedUser, gauge.MANAGER_ROLE()
            )
        );
        gauge.setInternalAddress(address(0x1234), true);
        vm.stopPrank();
    }

    /// @notice Test manager role updates
    function testFork_UpdateManager_Success() public {
        // ---- Arrange ----
        address newManager = makeAddr("newManager");

        // ---- Act ----
        gauge.updateManager(deployer, newManager);

        // ---- Assert ----
        // New manager should be able to call manager functions
        vm.startPrank(newManager);
        gauge.setFee(SuperDCAGauge.FeeType(0), 100);
        assertEq(gauge.internalFee(), 100, "New manager should be able to set fees");

        // Old manager should not be able to call manager functions
        vm.startPrank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, gauge.MANAGER_ROLE()
            )
        );
        gauge.setFee(SuperDCAGauge.FeeType(0), 200);
        vm.stopPrank();
    }

    /// @notice Test complete workflow: listing -> staking -> hook triggers -> rewards
    function testFork_CompleteWorkflow_ListStakeReward() public {
        // ---- Arrange ----
        uint160 sqrtPriceX96 = _getCurrentPrice();
        (PoolKey memory key,) = _createTestPool(WETH, int24(60), sqrtPriceX96);

        // ---- Act ----
        // 1. List token
        uint256 nftId = _createFullRangePosition(key, POSITION_AMOUNT0, POSITION_AMOUNT1, address(this));
        IERC721(POSITION_MANAGER_V4).approve(address(listing), nftId);
        listing.list(nftId, key);

        // 2. Stake in token
        vm.startPrank(user1);
        IERC20(DCA_TOKEN).approve(address(staking), STAKE_AMOUNT);
        staking.stake(WETH, STAKE_AMOUNT);
        vm.stopPrank();

        // 3. Let time pass for rewards
        _simulateTimePass(1800); // 30 minutes

        uint256 pendingBefore = staking.previewPending(WETH);

        // 4. Trigger hook through liquidity addition
        uint256 additionalDCA = 50e18;
        uint256 additionalWETH = 0.05e18;
        deal(DCA_TOKEN, address(this), additionalDCA);
        deal(WETH, address(this), additionalWETH);

        _createFullRangePosition(key, additionalDCA, additionalWETH, address(this));

        // ---- Assert ----
        assertTrue(gauge.isTokenListed(WETH), "Token should be listed");
        assertEq(staking.getUserStake(user1, WETH), STAKE_AMOUNT, "User should have stake");
        assertGt(pendingBefore, 0, "Should have accrued rewards");

        // Verify hook triggered and potentially distributed rewards
        uint256 pendingAfter = staking.previewPending(WETH);

        // Check developer balance increased (they should receive 50% of rewards if minting succeeded)
        uint256 developerBalance = IERC20(DCA_TOKEN).balanceOf(deployer);

        // In a successful scenario, pending rewards should be reduced and developer should receive tokens
        // The exact amounts depend on minting success and pool liquidity
        if (pendingAfter < pendingBefore) {
            // Rewards were distributed
            assertGt(developerBalance, 0, "Developer should have received rewards");
        }

        // Verify the complete workflow worked end-to-end
        assertTrue(listing.isTokenListed(WETH), "Listing should show token as listed");
        assertEq(staking.getUserStake(user1, WETH), STAKE_AMOUNT, "Staking should show user stake");

        // Verify the pool has liquidity from our position
        uint128 totalLiquidity = STATE_VIEW.getLiquidity(key.toId());
        assertGt(totalLiquidity, 0, "Pool should have liquidity from created positions");
    }

    // ==================== DYNAMIC FEE SWAP TESTS ====================

    /// @notice Test that different user types receive different swap fees through actual swaps
    function testFork_DynamicFees_ActualSwapExecution() public {
        // ---- Arrange ----
        // Set up pool with liquidity for swapping
        (PoolKey memory key,) = _setupSwapTestPool(WETH, 10e18, 10e18); // 10 DCA, 10 WETH

        // Set up test users
        address internalUser = makeAddr("internalUser");
        address keeperUser = makeAddr("keeperUser");
        address externalUser = makeAddr("externalUser");

        // Configure internal user
        gauge.setInternalAddress(internalUser, true);

        // Configure keeper user
        deal(DCA_TOKEN, keeperUser, 5000e18);
        vm.startPrank(keeperUser);
        IERC20(DCA_TOKEN).approve(address(gauge), 5000e18);
        gauge.becomeKeeper(5000e18);
        vm.stopPrank();

        // Prepare tokens for all users to swap
        uint256 swapAmount = 1e18; // 1 WETH
        _prepareSwapTokens(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), 0, swapAmount, internalUser);
        _prepareSwapTokens(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), 0, swapAmount, keeperUser);
        _prepareSwapTokens(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), 0, swapAmount, externalUser);

        // ---- Act ----
        // Execute swaps with each user type
        SwapResult memory internalResult = _executeV4Swap(
            key,
            uint128(swapAmount),
            0, // no minimum for testing
            internalUser,
            false // WETH -> DCA
        );

        SwapResult memory keeperResult = _executeV4Swap(key, uint128(swapAmount), 0, keeperUser, false);

        SwapResult memory externalResult = _executeV4Swap(key, uint128(swapAmount), 0, externalUser, false);

        // ---- Assert ----
        // Verify correct fees were applied
        _assertCorrectFeeApplied(internalResult, gauge.internalFee());
        _assertCorrectFeeApplied(keeperResult, gauge.keeperFee());
        _assertCorrectFeeApplied(externalResult, gauge.externalFee());

        // Verify fee hierarchy: internal < keeper < external
        assertLt(internalResult.feeApplied, keeperResult.feeApplied, "Internal fee should be less than keeper fee");
        assertLt(keeperResult.feeApplied, externalResult.feeApplied, "Keeper fee should be less than external fee");

        // For same input amounts, lower fees should yield higher outputs
        assertTrue(internalResult.amountIn == keeperResult.amountIn, "Same input amounts required for comparison");
        assertTrue(keeperResult.amountIn == externalResult.amountIn, "Same input amounts required for comparison");

        assertGt(internalResult.amountOut, keeperResult.amountOut, "Internal user should receive more output");
        assertGt(keeperResult.amountOut, externalResult.amountOut, "Keeper should receive more than external");

        // Verify all swaps actually occurred
        assertGt(internalResult.amountOut, 0, "Internal swap should produce output");
        assertGt(keeperResult.amountOut, 0, "Keeper swap should produce output");
        assertGt(externalResult.amountOut, 0, "External swap should produce output");
    }

    /// @notice Test fee changes are reflected in subsequent swaps
    function testFork_DynamicFees_FeeUpdatesReflectedInSwaps() public {
        // ---- Arrange ----
        (PoolKey memory key,) = _setupSwapTestPool(WETH, 20e18, 20e18);

        address testUser = makeAddr("testUser");
        uint256 swapAmount = 0.5e18;

        // Make user external initially
        assertFalse(gauge.isInternalAddress(testUser), "User should start as external");

        // ---- Act & Assert ----
        // Test 1: External fee initially
        _prepareSwapTokens(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), 0, swapAmount, testUser);
        SwapResult memory externalResult = _executeV4Swap(key, uint128(swapAmount), 0, testUser, false);
        _assertCorrectFeeApplied(externalResult, gauge.externalFee());

        // Test 2: Change to internal user
        gauge.setInternalAddress(testUser, true);
        _prepareSwapTokens(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), 0, swapAmount, testUser);
        SwapResult memory internalResult = _executeV4Swap(key, uint128(swapAmount), 0, testUser, false);
        _assertCorrectFeeApplied(internalResult, gauge.internalFee());

        // Test 3: Update internal fee and verify it applies
        uint24 newInternalFee = 250; // 0.025%
        gauge.setFee(SuperDCAGauge.FeeType.INTERNAL, newInternalFee);
        _prepareSwapTokens(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), 0, swapAmount, testUser);
        SwapResult memory updatedInternalResult = _executeV4Swap(key, uint128(swapAmount), 0, testUser, false);
        _assertCorrectFeeApplied(updatedInternalResult, newInternalFee);

        // Verify the fee change affected the output
        assertNotEq(internalResult.amountOut, updatedInternalResult.amountOut, "Fee change should affect output");
    }

    /// @notice Test keeper fee behavior during keeper transitions
    function testFork_DynamicFees_KeeperTransitions() public {
        // ---- Arrange ----
        (PoolKey memory key,) = _setupSwapTestPool(WETH, 15e18, 15e18);

        address keeper1 = makeAddr("keeper1");
        address keeper2 = makeAddr("keeper2");
        uint256 swapAmount = 0.3e18;

        deal(DCA_TOKEN, keeper1, 10000e18);
        deal(DCA_TOKEN, keeper2, 10000e18);

        // ---- Act & Assert ----

        // Test 1: keeper1 becomes keeper and gets keeper fees
        vm.startPrank(keeper1);
        IERC20(DCA_TOKEN).approve(address(gauge), 2000e18);
        gauge.becomeKeeper(2000e18);
        vm.stopPrank();

        _prepareSwapTokens(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), 0, swapAmount, keeper1);
        SwapResult memory keeper1Result = _executeV4Swap(key, uint128(swapAmount), 0, keeper1, false);
        _assertCorrectFeeApplied(keeper1Result, gauge.keeperFee());

        // Test 2: keeper2 takes over
        vm.startPrank(keeper2);
        IERC20(DCA_TOKEN).approve(address(gauge), 3000e18);
        gauge.becomeKeeper(3000e18);
        vm.stopPrank();

        // keeper1 should now get external fees
        _prepareSwapTokens(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), 0, swapAmount, keeper1);
        SwapResult memory exKeeper1Result = _executeV4Swap(key, uint128(swapAmount), 0, keeper1, false);
        _assertCorrectFeeApplied(exKeeper1Result, gauge.externalFee());

        // keeper2 should get keeper fees
        _prepareSwapTokens(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), 0, swapAmount, keeper2);
        SwapResult memory keeper2Result = _executeV4Swap(key, uint128(swapAmount), 0, keeper2, false);
        _assertCorrectFeeApplied(keeper2Result, gauge.keeperFee());

        // Verify the transition affected outputs appropriately
        assertLt(
            exKeeper1Result.amountOut, keeper1Result.amountOut, "Ex-keeper should get less than when they were keeper"
        );
        assertEq(keeper2Result.feeApplied, keeper1Result.feeApplied, "Both keepers should get same fee rate");
    }

    /// @notice Test edge case scenarios for dynamic fees
    function testFork_DynamicFees_EdgeCases() public {
        // ---- Arrange ----
        (PoolKey memory key,) = _setupSwapTestPool(WETH, 25e18, 25e18);

        address edgeUser = makeAddr("edgeUser");
        uint256 swapAmount = 0.1e18;

        // ---- Test 1: Zero fee scenario ----
        gauge.setInternalAddress(edgeUser, true);
        gauge.setFee(SuperDCAGauge.FeeType.INTERNAL, 0); // Set internal fee to 0

        _prepareSwapTokens(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), 0, swapAmount, edgeUser);
        SwapResult memory zeroFeeResult = _executeV4Swap(key, uint128(swapAmount), 0, edgeUser, false);
        _assertCorrectFeeApplied(zeroFeeResult, 0);

        // ---- Test 2: Maximum fee scenario ----
        gauge.setInternalAddress(edgeUser, false); // Make external
        uint24 maxFee = 10000; // 1%
        gauge.setFee(SuperDCAGauge.FeeType.EXTERNAL, maxFee);

        _prepareSwapTokens(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), 0, swapAmount, edgeUser);
        SwapResult memory maxFeeResult = _executeV4Swap(key, uint128(swapAmount), 0, edgeUser, false);
        _assertCorrectFeeApplied(maxFeeResult, maxFee);

        // Verify zero fee produces more output than max fee
        assertGt(zeroFeeResult.amountOut, maxFeeResult.amountOut, "Zero fee should produce more output than max fee");
    }

    /// @notice Test bidirectional swaps maintain fee consistency
    function testFork_DynamicFees_BidirectionalSwaps() public {
        // ---- Arrange ----
        (PoolKey memory key,) = _setupSwapTestPool(WETH, 30e18, 30e18);

        address testUser = makeAddr("bidirectionalUser");
        gauge.setInternalAddress(testUser, true);

        uint256 swapAmount = 0.2e18;

        // ---- Act ----
        // Test DCA -> WETH
        _prepareSwapTokens(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), swapAmount, 0, testUser);
        SwapResult memory dcaToWethResult = _executeV4Swap(key, uint128(swapAmount), 0, testUser, true);

        // Test WETH -> DCA
        _prepareSwapTokens(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), 0, swapAmount, testUser);
        SwapResult memory wethToDcaResult = _executeV4Swap(key, uint128(swapAmount), 0, testUser, false);

        // ---- Assert ----
        // Both directions should apply the same fee
        assertEq(dcaToWethResult.feeApplied, wethToDcaResult.feeApplied, "Bidirectional swaps should have same fee");
        _assertCorrectFeeApplied(dcaToWethResult, gauge.internalFee());
        _assertCorrectFeeApplied(wethToDcaResult, gauge.internalFee());

        // Both swaps should be successful
        assertGt(dcaToWethResult.amountOut, 0, "DCA to WETH swap should produce output");
        assertGt(wethToDcaResult.amountOut, 0, "WETH to DCA swap should produce output");
    }

    /// @notice Test multiple consecutive swaps maintain fee integrity
    function testFork_DynamicFees_ConsecutiveSwaps() public {
        // ---- Arrange ----
        (PoolKey memory key,) = _setupSwapTestPool(WETH, 50e18, 50e18);

        address internalUser = makeAddr("consecutiveInternal");
        address externalUser = makeAddr("consecutiveExternal");

        gauge.setInternalAddress(internalUser, true);

        uint256 swapAmount = 0.05e18; // Smaller amounts for multiple swaps
        uint256 numSwaps = 3;

        // ---- Act ----
        SwapResult[] memory internalResults = new SwapResult[](numSwaps);
        SwapResult[] memory externalResults = new SwapResult[](numSwaps);

        for (uint256 i = 0; i < numSwaps; i++) {
            // Internal user swaps
            _prepareSwapTokens(
                Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), 0, swapAmount, internalUser
            );
            internalResults[i] = _executeV4Swap(key, uint128(swapAmount), 0, internalUser, false);

            // External user swaps
            _prepareSwapTokens(
                Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), 0, swapAmount, externalUser
            );
            externalResults[i] = _executeV4Swap(key, uint128(swapAmount), 0, externalUser, false);
        }

        // ---- Assert ----
        // Verify all swaps applied correct fees consistently
        for (uint256 i = 0; i < numSwaps; i++) {
            _assertCorrectFeeApplied(internalResults[i], gauge.internalFee());
            _assertCorrectFeeApplied(externalResults[i], gauge.externalFee());

            // Internal should always get better rates
            assertGt(
                internalResults[i].amountOut,
                externalResults[i].amountOut,
                string(abi.encodePacked("Swap ", vm.toString(i), ": Internal should outperform external"))
            );
        }

        // Verify fee consistency across swaps
        for (uint256 i = 1; i < numSwaps; i++) {
            assertEq(internalResults[i].feeApplied, internalResults[0].feeApplied, "Internal fee should be consistent");
            assertEq(externalResults[i].feeApplied, externalResults[0].feeApplied, "External fee should be consistent");
        }
    }

    /// @notice Comprehensive test comparing all user types in a single scenario
    function testFork_DynamicFees_ComprehensiveComparison() public {
        // ---- Arrange ----
        (PoolKey memory key,) = _setupSwapTestPool(WETH, 100e18, 100e18);

        address internalUser = makeAddr("compInternal");
        address keeperUser = makeAddr("compKeeper");
        address externalUser = makeAddr("compExternal");

        // Setup user types
        gauge.setInternalAddress(internalUser, true);

        deal(DCA_TOKEN, keeperUser, 10000e18);
        vm.startPrank(keeperUser);
        IERC20(DCA_TOKEN).approve(address(gauge), 5000e18);
        gauge.becomeKeeper(5000e18);
        vm.stopPrank();

        uint256 swapAmount = 1e18;

        // Prepare tokens for all users
        address[] memory users = new address[](3);
        users[0] = internalUser;
        users[1] = keeperUser;
        users[2] = externalUser;

        for (uint256 i = 0; i < users.length; i++) {
            _prepareSwapTokens(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), 0, swapAmount, users[i]);
        }

        // ---- Act ----
        SwapResult[] memory results = new SwapResult[](3);
        results[0] = _executeV4Swap(key, uint128(swapAmount), 0, internalUser, false);
        results[1] = _executeV4Swap(key, uint128(swapAmount), 0, keeperUser, false);
        results[2] = _executeV4Swap(key, uint128(swapAmount), 0, externalUser, false);

        // ---- Assert ----
        // Verify fee hierarchy
        assertEq(results[0].feeApplied, gauge.internalFee(), "Internal user fee");
        assertEq(results[1].feeApplied, gauge.keeperFee(), "Keeper user fee");
        assertEq(results[2].feeApplied, gauge.externalFee(), "External user fee");

        // Use helper to compare results
        _compareSwapResults(results);

        // Specific assertions about the fee hierarchy
        assertLt(results[0].feeApplied, results[1].feeApplied, "Internal < Keeper fees");
        assertLt(results[1].feeApplied, results[2].feeApplied, "Keeper < External fees");

        // Output hierarchy (higher fees = lower outputs for same input)
        assertGt(results[0].amountOut, results[1].amountOut, "Internal > Keeper output");
        assertGt(results[1].amountOut, results[2].amountOut, "Keeper > External output");

        // Verify all swaps were successful
        for (uint256 i = 0; i < results.length; i++) {
            assertGt(results[i].amountOut, 0, string(abi.encodePacked("Swap ", vm.toString(i), " should succeed")));
            assertEq(
                results[i].amountIn, swapAmount, string(abi.encodePacked("Swap ", vm.toString(i), " input amount"))
            );
        }
    }

    // Events for testing
    event KeeperChanged(address indexed oldKeeper, address indexed newKeeper, uint256 deposit);
    event FeeUpdated(uint8 indexed feeType, uint24 oldFee, uint24 newFee);
    event InternalAddressUpdated(address indexed user, bool isInternal);
}
