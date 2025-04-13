// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {SuperDCAGauge} from "../src/SuperDCAGauge.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {console2} from "forge-std/Test.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";
import {ISuperchainERC20} from "../src/interfaces/ISuperchainERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

abstract contract DeployGaugeBase is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // Superchain ERC20 token is the same address on all Superchain's
    address public constant DCA_TOKEN = 0xDCa930875D1fB1E934aa8F085ed80f1A6af37cBC;

    struct HookConfiguration {
        address poolManager;
        address developerAddress;
        uint256 mintRate;
    }

    struct PoolConfiguration {
        // First token config (e.g. WETH)
        address token0;
        // Second token config (e.g. USDC)
        address token1;
        // Initial sqrt price for token0 pool
        uint160 initialSqrtPrice0;
        // Initial sqrt price for token1 pool
        uint160 initialSqrtPrice1;
    }

    uint256 public deployerPrivateKey;
    SuperDCAGauge public hook;

    function setUp() public virtual {
        deployerPrivateKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
    }

    function getHookConfiguration() public virtual returns (HookConfiguration memory);
    function getPoolConfiguration() public virtual returns (PoolConfiguration memory);

    function run() public virtual returns (SuperDCAGauge) {
        vm.startBroadcast(deployerPrivateKey);

        HookConfiguration memory hookConfig = getHookConfiguration();
        PoolConfiguration memory poolConfig = getPoolConfiguration();

        // Deploy hook with correct flags using HookMiner
        uint160 flags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);

        // Mine the salt that will produce a hook address with the correct flags
        bytes memory constructorArgs =
            abi.encode(hookConfig.poolManager, DCA_TOKEN, hookConfig.developerAddress, hookConfig.mintRate);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(SuperDCAGauge).creationCode, constructorArgs);

        // Deploy the hook using CREATE2 with the mined salt
        hook = new SuperDCAGauge{salt: salt}(
            IPoolManager(hookConfig.poolManager), DCA_TOKEN, hookConfig.developerAddress, hookConfig.mintRate
        );

        require(address(hook) == hookAddress, "Hook address mismatch");

        console2.log("Deployed Hook:", address(hook));

        // Add the hook as a minter on the DCA token
        ISuperchainERC20(DCA_TOKEN).grantRole(MINTER_ROLE, address(hook));
        console2.log("Granted MINTER_ROLE to hook:", address(hook));

        // Stake the ETH token to the hook with 600 DCA
        IERC20(DCA_TOKEN).approve(address(hook), 1000 ether);
        hook.stake(poolConfig.token0, 600 ether);

        console2.log("Staked 600 ETH to the hook");

        // Stake the USDC token to the hook with 400 DCA
        hook.stake(poolConfig.token1, 400 ether);

        console2.log("Staked 400 USDC to the hook");

        // Create pool keys for both USDC/DCA and ETH/DCA pools
        PoolKey memory usdcPoolKey = PoolKey({
            currency0: address(DCA_TOKEN) < poolConfig.token1 ? Currency.wrap(DCA_TOKEN) : Currency.wrap(poolConfig.token1),
            currency1: address(DCA_TOKEN) < poolConfig.token1 ? Currency.wrap(poolConfig.token1) : Currency.wrap(DCA_TOKEN),
            fee: 500,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        PoolKey memory ethPoolKey = PoolKey({
            currency0: address(DCA_TOKEN) < poolConfig.token0 ? Currency.wrap(DCA_TOKEN) : Currency.wrap(poolConfig.token0),
            currency1: address(DCA_TOKEN) < poolConfig.token0 ? Currency.wrap(poolConfig.token0) : Currency.wrap(DCA_TOKEN),
            fee: 500,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        // Initialize both pools
        IPoolManager(hookConfig.poolManager).initialize(usdcPoolKey, poolConfig.initialSqrtPrice1);
        IPoolManager(hookConfig.poolManager).initialize(ethPoolKey, poolConfig.initialSqrtPrice0);
        console2.log("Initialized USDC/DCA and ETH/DCA Pools");

        // Add 10K DCA + 10K FUSDC to the Uniswap V4 pool
        mintLiquidityPosition(
            hookConfig.poolManager,
            DCA_TOKEN,
            poolConfig.token1,
            10_000 ether, // 10K DCA 
            10_000 * (10**6), // 10K FUSDC (assuming 6 decimals)
            poolConfig.initialSqrtPrice1
        );
        console2.log("Added 10K DCA + 10K FUSDC liquidity to Uniswap V4 pool");

        // Add 10K DCA + 10K FDAI to the Uniswap V4 pool
        mintLiquidityPosition(
            hookConfig.poolManager,
            DCA_TOKEN,
            poolConfig.token0,
            10_000 ether, // 10K DCA
            10_000 ether, // 10K FDAI (assuming 18 decimals)
            poolConfig.initialSqrtPrice0
        );
        console2.log("Added 10K DCA + 10K FDAI liquidity to Uniswap V4 pool");

        vm.stopBroadcast();

        return hook;
    }
    
    function mintLiquidityPosition(
        address poolManager,
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        uint160 initialSqrtPrice
    ) internal {
        // Get position manager address - you'll need to set this for your deployment
        address positionManagerAddress = 0x0000000000000000000000000000000000000000; // TODO: Replace with actual address
        IPositionManager positionManager = IPositionManager(positionManagerAddress);
        
        // Sort tokens to determine currency0 and currency1
        (address token0, address token1, uint256 amount0, uint256 amount1) = tokenA < tokenB 
            ? (tokenA, tokenB, amountA, amountB)
            : (tokenB, tokenA, amountB, amountA);
            
        // Encode actions for mint position and settle pair
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        
        // Encode parameters
        bytes[] memory params = new bytes[](2);
        
        // Create PoolKey
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 500, // 0.05% fee tier
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        
        // Calculate tick range for full range liquidity
        int24 tickLower = -887272;
        int24 tickUpper = 887272;
        
        // Convert tick bounds to sqrt price bounds
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtRatioAtTick(tickUpper);
        
        // Calculate the liquidity based on token amounts and price bounds
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            initialSqrtPrice,
            sqrtPriceLowerX96,
            sqrtPriceUpperX96,
            amount0,
            amount1
        );
        
        // Encode MINT_POSITION parameters
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            uint128(amount0),
            uint128(amount1),
            address(this), // recipient
            bytes("") // hookData - empty for now
        );
        
        // Encode SETTLE_PAIR parameters
        params[1] = abi.encode(Currency.wrap(token0), Currency.wrap(token1));
        
        // Approve tokens if needed
        IERC20(token0).approve(address(positionManager), amount0);
        IERC20(token1).approve(address(positionManager), amount1);
        
        // Submit call
        uint256 deadline = block.timestamp + 60;
        
        // Handle ETH if one token is native ETH
        uint256 valueToPass = 0; // If dealing with ETH, this would be non-zero
        
        positionManager.modifyLiquidities{value: valueToPass}(
            abi.encode(actions, params),
            deadline
        );
    }
}
