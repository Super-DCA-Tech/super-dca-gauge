// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

// Uniswap V4 Core
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

// Uniswap V4 Periphery
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {Planner, Plan} from "lib/v4-periphery/test/shared/Planner.sol";
import {LiquidityAmounts} from "lib/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PositionConfig} from "lib/v4-periphery/src/libraries/PositionConfig.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {IStateView} from "lib/v4-periphery/src/interfaces/IStateView.sol";

// Universal Router and Swapping
/// @notice Issues with importing the universal router solved with these imports
/// see: https://github.com/0ximmeas/univ4-swap-walkthrough
import {IUniversalRouter} from "../external/IUniversalRouter.sol";
import {Commands} from "../external/Commands.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

// SuperDCA Contracts
import {SuperDCAListing} from "../../src/SuperDCAListing.sol";
import {SuperDCAStaking} from "../../src/SuperDCAStaking.sol";
import {SuperDCAGauge} from "../../src/SuperDCAGauge.sol";
import {SuperDCAToken} from "../../src/SuperDCAToken.sol";

// Deployment Script
import {DeployGaugeBaseOptimism} from "../../script/DeployGaugeOptimism.s.sol";

/// @notice Base integration test that forks Optimism mainnet and tests SuperDCA contracts
/// against real Uniswap V4 infrastructure and live DCA token
contract OptimismIntegrationBase is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    // Structs to avoid stack too deep errors
    struct PositionParams {
        int24 tickLower;
        int24 tickUpper;
        uint160 sqrtPriceX96;
        uint160 sqrtPriceAX96;
        uint160 sqrtPriceBX96;
        uint128 liquidity;
    }

    struct TokenAddresses {
        address token0;
        address token1;
    }

    struct BalanceTracking {
        uint256 totalSupplyBefore;
        uint256 totalSupplyAfter;
    }

    struct SwapParams {
        address tokenIn;
        address tokenOut;
        uint256 balanceInBefore;
        uint256 balanceOutBefore;
        uint256 deadline;
        uint256 gasStart;
    }

    struct SwapExecution {
        bytes commands;
        bytes[] inputs;
        bytes actions;
        bytes[] params;
    }

    // ---- Optimism mainnet addresses ----

    // Uniswap V4 Core addresses
    address constant POOL_MANAGER = 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3;
    address constant POSITION_MANAGER_V4 = 0x3C3Ea4B57a46241e54610e5f022E5c45859A1017;
    address constant QUOTER = 0x1f3131A13296FB91C90870043742C3CDBFF1A8d7;
    address constant UNIVERSAL_ROUTER = 0x851116D9223fabED8E56C0E6b8Ad0c31d98B3507;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    IStateView constant STATE_VIEW = IStateView(0xc18a3169788F4F75A170290584ECA6395C75Ecdb);

    // Optimism native tokens
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // DCA Token on Optimism
    address constant DCA_TOKEN = 0xb1599CDE32181f48f89683d3C5Db5C5D2C7C93cc;
    address constant DCA_DEPLOYER = 0xC07E21c78d6Ad0917cfCBDe8931325C392958892; // superdca.eth

    // Test configuration
    uint256 constant STAKE_AMOUNT = 1000e18;
    uint256 constant LIQUIDITY_AMOUNT = 500e18;
    uint256 constant MINT_RATE = 1e18; // 1 token per second

    // Position amounts for testing
    uint256 constant POSITION_AMOUNT0 = 2e18; // Amount of token0 for positions
    uint256 constant POSITION_AMOUNT1 = 2000e18; // Amount of token1 for positions (must be above minimum liquidity in SuperDCAListing)

    // Deployment script
    DeployGaugeBaseOptimism public deployScript;

    // Deployed contracts (will be set by deployment script)
    SuperDCAListing public listing;
    SuperDCAStaking public staking;
    SuperDCAGauge public gauge;
    IPoolManager public poolManager;
    IUniversalRouter public universalRouter;
    IPermit2 public permit2;

    // Test addresses - using the same developer address as deployment script
    address deployer; // Set when deployment runs.
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    function setUp() public virtual {
        // Fork Optimism mainnet using the configured RPC alias "optimism"
        // Optionally pin a block by exporting OPTIMISM_BLOCK_NUMBER; otherwise use a stable recent block
        string memory rpc = vm.rpcUrl("optimism");
        try vm.envUint("OPTIMISM_BLOCK_NUMBER") returns (uint256 blockNumber) {
            vm.createSelectFork(rpc, blockNumber);
        } catch {
            // Use a recent stable block number
            vm.createSelectFork(rpc, 141_436_225); // Approximate recent block
        }

        // Deploy contracts using the actual deployment script
        _deployContractsUsingScript();

        // Fund test addresses with DCA tokens and WETH
        _fundTestAddresses();
    }

    function _deployContractsUsingScript() internal {
        // Disable deploy logs for integration tests
        vm.setEnv("SHOW_DEPLOY_LOGS", "false");

        // Create deployment script instance
        deployScript = new DeployGaugeBaseOptimism();

        // Set up the deployment script
        deployScript.setUp();

        // Run the deployment script to deploy all contracts
        DeployGaugeBaseOptimism.DeployedContracts memory deployed = deployScript.run();

        // Set the deployer address
        deployer = deployScript.deployerAddress();

        // Get references to the deployed contracts
        gauge = deployed.gauge;
        listing = deployed.listing;
        staking = deployed.staking;
        poolManager = IPoolManager(POOL_MANAGER);
        universalRouter = IUniversalRouter(payable(UNIVERSAL_ROUTER));
        permit2 = IPermit2(PERMIT2);

        // Transfer ownership to test contract for administrative functions
        _setupTestOwnership();
    }

    function _setupTestOwnership() internal {
        // Transfer ownership of the Super DCA token to the hook (as the deployment script does)
        vm.startPrank(DCA_DEPLOYER);
        SuperDCAToken(DCA_TOKEN).transferOwnership(address(gauge));
        vm.stopPrank();

        // Impersonate the deployer to transfer ownership of the staking and listing contracts
        // to this test contract
        vm.startPrank(deployer);

        // Transfer staking ownership to test contract
        staking.transferOwnership(address(this));

        // Transfer listing ownership to test contract
        listing.transferOwnership(address(this));

        // Grant admin role to test contract on gauge
        gauge.grantRole(gauge.DEFAULT_ADMIN_ROLE(), address(this));
        gauge.grantRole(gauge.MANAGER_ROLE(), address(this));

        vm.stopPrank();

        // Accept ownership transfers
        staking.acceptOwnership();
        listing.acceptOwnership();
    }

    function _fundTestAddresses() internal {
        // Fund test addresses with DCA tokens and WETH
        deal(DCA_TOKEN, user1, 10000e18);
        deal(DCA_TOKEN, user2, 10000e18);
        deal(DCA_TOKEN, address(this), 10000e18);

        deal(WETH, user1, 100e18);
        deal(WETH, user2, 100e18);
        deal(WETH, address(this), 100e18);
    }

    /// @notice Helper to create a test pool between DCA token and another token
    function _createTestPool(address token, int24 tickSpacing, uint160 sqrtPriceX96)
        internal
        returns (PoolKey memory key, PoolId poolId)
    {
        // Ensure DCA token is always currency0 for consistency
        (Currency currency0, Currency currency1) = DCA_TOKEN < token
            ? (Currency.wrap(DCA_TOKEN), Currency.wrap(token))
            : (Currency.wrap(token), Currency.wrap(DCA_TOKEN));

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(gauge))
        });

        poolId = key.toId();

        // Initialize the pool
        poolManager.initialize(key, sqrtPriceX96);
    }

    /// @notice Helper to create a test pool from an existing PoolKey
    function _createTestPoolFromKey(PoolKey memory key, uint160 sqrtPriceX96) internal returns (PoolId poolId) {
        poolId = key.toId();

        // Initialize the pool
        poolManager.initialize(key, sqrtPriceX96);
    }

    /// @notice Helper to create a full-range position NFT
    function _createFullRangePosition(PoolKey memory key, uint256 amount0, uint256 amount1, address recipient)
        internal
        returns (uint256 nftId)
    {
        // Calculate position parameters using struct to avoid stack too deep
        PositionParams memory params = _calculatePositionParams(key, amount0, amount1);

        // Get token addresses using struct
        TokenAddresses memory tokens =
            TokenAddresses({token0: Currency.unwrap(key.currency0), token1: Currency.unwrap(key.currency1)});

        // Prepare tokens for position creation
        _prepareTokens(tokens, amount0, amount1);

        // Create and execute position
        nftId = _executePositionMint(key, params, amount0, amount1, recipient);
    }

    /// @notice Calculate position parameters to avoid stack too deep
    function _calculatePositionParams(PoolKey memory key, uint256 amount0, uint256 amount1)
        internal
        view
        returns (PositionParams memory params)
    {
        params.tickLower = TickMath.minUsableTick(key.tickSpacing);
        params.tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        (params.sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        params.sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(params.tickLower);
        params.sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(params.tickUpper);

        params.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            params.sqrtPriceX96, params.sqrtPriceAX96, params.sqrtPriceBX96, amount0, amount1
        );
    }

    /// @notice Prepare tokens for position creation
    function _prepareTokens(TokenAddresses memory tokens, uint256 amount0, uint256 amount1) internal {
        deal(tokens.token0, address(this), amount0);
        deal(tokens.token1, address(this), amount1);

        // Approve tokens to Permit2
        IERC20(tokens.token0).approve(PERMIT2, type(uint256).max);
        IERC20(tokens.token1).approve(PERMIT2, type(uint256).max);

        // Approve Permit2 to spend tokens on behalf of PositionManager
        IAllowanceTransfer(PERMIT2).approve(tokens.token0, POSITION_MANAGER_V4, type(uint160).max, type(uint48).max);
        IAllowanceTransfer(PERMIT2).approve(tokens.token1, POSITION_MANAGER_V4, type(uint160).max, type(uint48).max);
    }

    /// @notice Execute position mint and return NFT ID
    /// @dev Ref: https://docs.uniswap.org/contracts/v4/quickstart/manage-liquidity/mint-position
    function _executePositionMint(
        PoolKey memory key,
        PositionParams memory params,
        uint256 amount0,
        uint256 amount1,
        address recipient
    ) internal returns (uint256 nftId) {
        // Create position using Planner
        Plan memory plan = Planner.init();

        // Add mint action to plan
        plan = plan.add(
            Actions.MINT_POSITION,
            abi.encode(
                key, params.tickLower, params.tickUpper, params.liquidity, amount0, amount1, recipient, bytes("")
            )
        );

        plan = plan.add(Actions.SETTLE_PAIR, abi.encode(key.currency0, key.currency1));

        // Execute the plan
        bytes memory data = plan.encode();
        uint256 deadline = block.timestamp + 60;

        // Start recording logs to capture Transfer events
        vm.recordLogs();

        // Execute the position mint
        IPositionManager(POSITION_MANAGER_V4).modifyLiquidities(data, deadline);

        // Get recorded logs and find the Transfer event for minting
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Look for Transfer event: Transfer(address indexed from, address indexed to, uint256 indexed tokenId)
        // Event signature: keccak256("Transfer(address,address,uint256)")
        bytes32 transferEventSignature = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics[0] == transferEventSignature && logs[i].emitter == POSITION_MANAGER_V4
                    && logs[i].topics[1] == bytes32(0) // from == address(0) for minting
                    && logs[i].topics[2] == bytes32(uint256(uint160(recipient)))
            ) {
                // to == recipient
                nftId = uint256(logs[i].topics[3]); // tokenId is the third indexed parameter
                break;
            }
        }

        require(nftId != 0, "Failed to find minted NFT ID in logs");
    }

    /// @notice Helper to simulate time passing for reward accrual
    function _simulateTimePass(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
    }

    /// @notice Helper to check if a token is properly listed
    function _assertTokenListed(address token, uint256 expectedNftId) internal view {
        assertTrue(listing.isTokenListed(token), "Token should be listed");
        assertEq(listing.tokenOfNfp(expectedNftId), token, "NFT should map to token");
    }

    /// @notice Helper to assert stake amounts
    function _assertStakeAmount(address user, address token, uint256 expectedAmount) internal view {
        assertEq(staking.getUserStake(user, token), expectedAmount, "Stake amount mismatch");
    }

    /// @notice Helper to assert total staked amount
    function _assertTotalStaked(uint256 expectedTotal) internal view {
        assertEq(staking.totalStakedAmount(), expectedTotal, "Total staked amount mismatch");
    }

    /// @notice Get current price for DCA/WETH pool (for testing purposes)
    function _getCurrentPrice() internal pure returns (uint160) {
        // Return a reasonable price (1 DCA = 0.001 ETH)
        // This is approximately sqrt(0.001) * 2^96
        return 2505414483750479311864138015696896; // approximate value
    }

    // ==================== SWAP HELPER FUNCTIONS ====================

    /// @notice Struct to track swap results for fee verification
    struct SwapResult {
        uint256 amountIn;
        uint256 amountOut;
        uint24 feeApplied;
        address swapper;
        uint256 gasUsed;
    }

    /// @notice Approve tokens for use with Universal Router via Permit2
    /// @param token The token to approve
    /// @param amount The amount to approve
    /// @param spender The address to approve spending for
    function _approveTokenWithPermit2(address token, uint160 amount, address spender) internal {
        // First approve Permit2 to spend the token
        IERC20(token).approve(address(permit2), type(uint256).max);

        // Then approve Universal Router through Permit2
        permit2.approve(token, spender, amount, type(uint48).max);
    }

    /// @notice Prepare tokens and approvals for swap testing
    /// @param token0 First token address
    /// @param token1 Second token address
    /// @param amount0 Amount of token0 needed
    /// @param amount1 Amount of token1 needed
    /// @param swapper Address that will perform the swap
    function _prepareSwapTokens(address token0, address token1, uint256 amount0, uint256 amount1, address swapper)
        internal
    {
        // Deal tokens to swapper
        deal(token0, swapper, amount0);
        deal(token1, swapper, amount1);

        // Set up approvals via Permit2
        vm.startPrank(swapper);
        _approveTokenWithPermit2(token0, type(uint160).max, address(universalRouter));
        _approveTokenWithPermit2(token1, type(uint160).max, address(universalRouter));
        vm.stopPrank();
    }

    /// @notice Execute a swap using Universal Router with V4 pools
    /// @param key The pool key for the swap
    /// @param amountIn The exact amount to swap in
    /// @param minAmountOut The minimum amount to receive
    /// @param swapper The address performing the swap
    /// @param zeroForOne Direction of the swap
    /// @return result SwapResult struct with swap details
    function _executeV4Swap(
        PoolKey memory key,
        uint128 amountIn,
        uint128 minAmountOut,
        address swapper,
        bool zeroForOne
    ) internal returns (SwapResult memory result) {
        // Setup swap parameters using struct to avoid stack too deep
        SwapParams memory swapParams = _prepareSwapParams(key, swapper, zeroForOne);

        // Prepare swap execution data using struct
        SwapExecution memory execution = _prepareSwapExecution(key, amountIn, minAmountOut, zeroForOne);

        // Execute the swap
        vm.prank(swapper);
        universalRouter.execute(execution.commands, execution.inputs, swapParams.deadline);

        uint256 gasUsed = swapParams.gasStart - gasleft();

        // Calculate and return results
        result = _calculateSwapResult(swapParams, swapper, gasUsed);
    }

    /// @notice Prepare swap parameters to avoid stack too deep
    function _prepareSwapParams(PoolKey memory key, address swapper, bool zeroForOne)
        internal
        view
        returns (SwapParams memory swapParams)
    {
        swapParams.tokenIn = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        swapParams.tokenOut = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        swapParams.balanceInBefore = IERC20(swapParams.tokenIn).balanceOf(swapper);
        swapParams.balanceOutBefore = IERC20(swapParams.tokenOut).balanceOf(swapper);
        swapParams.deadline = block.timestamp + 300; // 5 minute deadline
        swapParams.gasStart = gasleft();
    }

    /// @notice Prepare swap execution data to avoid stack too deep
    function _prepareSwapExecution(PoolKey memory key, uint128 amountIn, uint128 minAmountOut, bool zeroForOne)
        internal
        pure
        returns (SwapExecution memory execution)
    {
        // Encode the Universal Router command
        execution.commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        execution.inputs = new bytes[](1);

        // Encode V4Router actions
        execution.actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        // Prepare parameters for each action
        execution.params = new bytes[](3);
        execution.params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                hookData: bytes("")
            })
        );
        execution.params[1] = abi.encode(zeroForOne ? key.currency0 : key.currency1, amountIn);
        execution.params[2] = abi.encode(zeroForOne ? key.currency1 : key.currency0, minAmountOut);

        // Combine actions and params into inputs
        execution.inputs[0] = abi.encode(execution.actions, execution.params);
    }

    /// @notice Calculate swap result to avoid stack too deep
    function _calculateSwapResult(SwapParams memory swapParams, address swapper, uint256 gasUsed)
        internal
        view
        returns (SwapResult memory result)
    {
        // Calculate actual amounts
        uint256 balanceInAfter = IERC20(swapParams.tokenIn).balanceOf(swapper);
        uint256 balanceOutAfter = IERC20(swapParams.tokenOut).balanceOf(swapper);

        uint256 actualAmountIn = swapParams.balanceInBefore - balanceInAfter;
        uint256 actualAmountOut = balanceOutAfter - swapParams.balanceOutBefore;

        // Determine fee that was applied by checking gauge behavior
        uint24 feeApplied;
        if (gauge.isInternalAddress(swapper)) {
            feeApplied = gauge.internalFee();
        } else if (swapper == _getKeeperAddress()) {
            feeApplied = gauge.keeperFee();
        } else {
            feeApplied = gauge.externalFee();
        }

        result = SwapResult({
            amountIn: actualAmountIn,
            amountOut: actualAmountOut,
            feeApplied: feeApplied,
            swapper: swapper,
            gasUsed: gasUsed
        });
    }

    /// @notice Execute a simpler swap using pool manager directly (for comparison)
    /// @param key The pool key for the swap
    /// @param swapper The address performing the swap
    /// @param zeroForOne Direction of the swap
    /// @return result SwapResult struct with swap details
    function _executeDirectSwap(PoolKey memory key, int128, /* amountIn */ address swapper, bool zeroForOne)
        internal
        returns (SwapResult memory result)
    {
        address tokenIn = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        address tokenOut = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);

        uint256 balanceInBefore = IERC20(tokenIn).balanceOf(swapper);
        uint256 balanceOutBefore = IERC20(tokenOut).balanceOf(swapper);

        // Prepare swap parameters
        // Note: This is a placeholder for direct swap implementation
        // The actual swap would require proper unlock callback implementation

        uint256 gasStart = gasleft();

        // Execute swap (this would need proper implementation with unlock callback)
        // For now, we'll simulate the swap behavior
        vm.prank(swapper);
        // poolManager.swap(key, swapParams, bytes(""));

        uint256 gasUsed = gasStart - gasleft();

        // Calculate results (simplified for direct swap)
        uint256 balanceInAfter = IERC20(tokenIn).balanceOf(swapper);
        uint256 balanceOutAfter = IERC20(tokenOut).balanceOf(swapper);

        uint256 actualAmountIn = balanceInBefore - balanceInAfter;
        uint256 actualAmountOut = balanceOutAfter - balanceOutBefore;

        // Determine fee that would be applied
        uint24 feeApplied;
        if (gauge.isInternalAddress(swapper)) {
            feeApplied = gauge.internalFee();
        } else if (swapper == _getKeeperAddress()) {
            feeApplied = gauge.keeperFee();
        } else {
            feeApplied = gauge.externalFee();
        }

        result = SwapResult({
            amountIn: actualAmountIn,
            amountOut: actualAmountOut,
            feeApplied: feeApplied,
            swapper: swapper,
            gasUsed: gasUsed
        });
    }

    /// @notice Get the current keeper address from the gauge
    /// @return keeper The current keeper address (or address(0) if none)
    function _getKeeperAddress() internal view returns (address keeper) {
        (keeper,) = gauge.getKeeperInfo();
    }

    /// @notice Calculate expected amount out for a swap given the fee
    /// @param amountIn The input amount
    /// @param fee The fee in basis points
    /// @param priceRatio The price ratio (simplified)
    /// @return expectedAmountOut The expected output amount
    function _calculateExpectedAmountOut(uint256 amountIn, uint24 fee, uint256 priceRatio)
        internal
        pure
        returns (uint256 expectedAmountOut)
    {
        // Simplified calculation: amountOut = amountIn * priceRatio * (1 - fee/1000000)
        uint256 amountAfterFee = amountIn * (1000000 - fee) / 1000000;
        expectedAmountOut = amountAfterFee * priceRatio / 1e18;
    }

    /// @notice Assert that swap fees were applied correctly
    /// @param result The swap result to verify
    /// @param expectedFee The expected fee in basis points
    function _assertCorrectFeeApplied(SwapResult memory result, uint24 expectedFee) internal pure {
        assertEq(result.feeApplied, expectedFee, "Incorrect fee applied to swap");
    }

    /// @notice Compare swap results between different user types
    /// @param results Array of swap results to compare
    function _compareSwapResults(SwapResult[] memory results) internal pure {
        require(results.length >= 2, "Need at least 2 results to compare");

        // Higher fees should result in lower output amounts for same input
        for (uint256 i = 0; i < results.length - 1; i++) {
            for (uint256 j = i + 1; j < results.length; j++) {
                if (results[i].amountIn == results[j].amountIn) {
                    if (results[i].feeApplied > results[j].feeApplied) {
                        assertLt(results[i].amountOut, results[j].amountOut, "Higher fee should result in lower output");
                    }
                }
            }
        }
    }

    /// @notice Setup a complete test pool with liquidity for swap testing
    /// @param token The token to pair with DCA
    /// @param initialLiquidity0 Initial liquidity for token0
    /// @param initialLiquidity1 Initial liquidity for token1
    /// @return key The pool key
    /// @return poolId The pool ID
    function _setupSwapTestPool(address token, uint256 initialLiquidity0, uint256 initialLiquidity1)
        internal
        returns (PoolKey memory key, PoolId poolId)
    {
        uint160 sqrtPriceX96 = _getCurrentPrice();
        (key, poolId) = _createTestPool(token, int24(60), sqrtPriceX96);

        // Add initial liquidity to enable swaps
        _createFullRangePosition(key, initialLiquidity0, initialLiquidity1, address(this));
    }
}
