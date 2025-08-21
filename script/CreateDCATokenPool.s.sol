// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

/**
 * @title CreateDCATokenPool
 * @notice Script to create a Uniswap V4 liquidity pool for DCA and any token
 * @dev Usage:
 *   forge script script/CreateDCATokenPool.s.sol:CreateDCATokenPool --rpc-url <RPC_URL> --broadcast
 *
 * Configuration:
 *   Edit the constants below to configure the deployment for your specific network and token.
 *
 * Example (Base WBTC-DCA pool deployment):
 *   - Set POOL_MANAGER_ADDRESS = 0x498581fF718922c3f8e6A244956aF099B2652b2b
 *   - Set HOOK_ADDRESS = 0xBc5F29A583a8d3ec76e03372659e01a22feE3A80
 *   - Set TOKEN_ADDRESS = 0x0555e30da8f98308edb960aa94c0db47230d2b9c (Base WBTC)
 *   forge script script/CreateDCATokenPool.s.sol:CreateDCATokenPool --rpc-url $BASE_RPC_URL --broadcast
 */
import {Script} from "forge-std/Script.sol";
import {SuperDCAGauge} from "../src/SuperDCAGauge.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {console2} from "forge-std/Test.sol";

contract CreateDCATokenPool is Script {
    // ============ CONFIGURATION CONSTANTS ============
    // Edit these values for your specific deployment

    // Deployer private key - retrieved from environment variable
    uint256 deployerPrivateKey;

    // Pool Manager address - REQUIRED: Set this to your network's Pool Manager
    address public constant POOL_MANAGER_ADDRESS = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    // Hook address - REQUIRED: Set this to your deployed SuperDCAGauge hook
    address public constant HOOK_ADDRESS = 0xBc5F29A583a8d3ec76e03372659e01a22feE3A80;

    // Token address - REQUIRED: Set this to the token you want to pair with DCA
    // Examples:
    // - Base WBTC: 0x0555e30da8f98308edb960aa94c0db47230d2b9c
    // - Base Aave: 0x498581fF718922c3f8e6A244956aF099B2652b2b
    // - Mainnet WBTC: 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599
    address public constant TOKEN_ADDRESS = 0x63706e401c06ac8513145b7687A14804d17f814b;

    // Initial pool price as sqrtPriceX96
    // Default value represents approximately reserves of 1e18 : 1000e18
    uint160 public constant INITIAL_SQRT_PRICE_X96 = 2505414483750479311864138015696;

    // DCA Token is constant across all Superchain networks
    address public constant DCA_TOKEN = 0xb1599CDE32181f48f89683d3C5Db5C5D2C7C93cc;

    // ============ VALIDATION ============

    function validateConfiguration() internal pure {
        require(POOL_MANAGER_ADDRESS != address(0), "POOL_MANAGER_ADDRESS must be set");
        require(HOOK_ADDRESS != address(0), "HOOK_ADDRESS must be set");
        require(TOKEN_ADDRESS != address(0), "TOKEN_ADDRESS must be set");
        require(TOKEN_ADDRESS != DCA_TOKEN, "TOKEN_ADDRESS cannot be the same as DCA_TOKEN");
    }

    // ============ SCRIPT EXECUTION ============

    function setUp() public {
        deployerPrivateKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
    }

    function run() public {
        validateConfiguration();

        vm.startBroadcast(deployerPrivateKey);

        IPoolManager poolManager = IPoolManager(POOL_MANAGER_ADDRESS);
        SuperDCAGauge hook = SuperDCAGauge(payable(HOOK_ADDRESS));

        console2.log("=== Pool Creation Configuration ===");
        console2.log("Pool Manager:", address(poolManager));
        console2.log("Hook Address:", address(hook));
        console2.log("DCA Token:", DCA_TOKEN);
        console2.log("Paired Token:", TOKEN_ADDRESS);
        console2.log("Initial Sqrt Price X96:", INITIAL_SQRT_PRICE_X96);

        // Create pool key for DCA/TOKEN pool
        // Currency0 should be the smaller address
        PoolKey memory dcaTokenPoolKey = PoolKey({
            // TODO: Must be set manually
            currency0: Currency.wrap(TOKEN_ADDRESS),
            currency1: Currency.wrap(DCA_TOKEN),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(hook)
        });

        console2.log("=== Pool Key Details ===");
        console2.log("Currency0:", Currency.unwrap(dcaTokenPoolKey.currency0));
        console2.log("Currency1:", Currency.unwrap(dcaTokenPoolKey.currency1));
        console2.log("Fee:", dcaTokenPoolKey.fee);
        console2.log("Tick Spacing:", dcaTokenPoolKey.tickSpacing);

        console2.log("=== Initializing Pool ===");
        int24 tick = poolManager.initialize(dcaTokenPoolKey, INITIAL_SQRT_PRICE_X96);
        console2.log("Pool initialized successfully!");
        console2.log("Initial tick:", tick);

        vm.stopBroadcast();
    }
}
