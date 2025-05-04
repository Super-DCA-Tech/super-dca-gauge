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
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {console2} from "forge-std/Test.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";
import {ISuperchainERC20} from "../src/interfaces/ISuperchainERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract DeployGaugeBase is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // Superchain ERC20 token is the same address on all Superchain's
    address public constant DCA_TOKEN = 0xdCA0423d8a8b0e6c9d7756C16Ed73f36f1BadF54;

    // Initial sqrtPriceX96 for the pools
    uint160 public constant INITIAL_SQRT_PRICE_X96_USDC = 79228162514264337593543950336000000; // 1 DCA:1 USDC
    uint160 public constant INITIAL_SQRT_PRICE_X96_WETH = 3266660825699135604008626946048; // 1 DCA:2700 ETH

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
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG
        );

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
        console2.log("DCA Token:", DCA_TOKEN);
        console2.log("Hook:", address(hook));
        console2.log("Deployer:", vm.addr(deployerPrivateKey));
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
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        PoolKey memory ethPoolKey = PoolKey({
            currency0: address(DCA_TOKEN) < poolConfig.token0 ? Currency.wrap(DCA_TOKEN) : Currency.wrap(poolConfig.token0),
            currency1: address(DCA_TOKEN) < poolConfig.token0 ? Currency.wrap(poolConfig.token0) : Currency.wrap(DCA_TOKEN),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        // Initialize both pools
        IPoolManager(hookConfig.poolManager).initialize(usdcPoolKey, INITIAL_SQRT_PRICE_X96_USDC);
        IPoolManager(hookConfig.poolManager).initialize(ethPoolKey, INITIAL_SQRT_PRICE_X96_WETH);
        console2.log("Initialized USDC/DCA and ETH/DCA Pools");

        vm.stopBroadcast();

        return hook;
    }
}
