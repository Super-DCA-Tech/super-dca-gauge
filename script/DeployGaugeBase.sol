// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {SuperDCAGauge} from "../src/SuperDCAGauge.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {console2} from "forge-std/Test.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";
import {ISuperchainERC20} from "../src/interfaces/ISuperchainERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {SuperDCAStaking} from "../src/SuperDCAStaking.sol";
import {SuperDCAListing} from "../src/SuperDCAListing.sol";

abstract contract DeployGaugeBase is Script {
    using CurrencyLibrary for Currency;

    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    // bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // Superchain ERC20 token is the same address on all Superchain's
    address public constant DCA_TOKEN = 0xb1599CDE32181f48f89683d3C5Db5C5D2C7C93cc;

    // Initial sqrtPriceX96 for the pools
    uint160 public constant INITIAL_SQRT_PRICE_X96_USDC = 101521246766866706223754711356428849; // SQRT_PRICE_1_2 (0.5 USDC/DCA)
    uint160 public constant INITIAL_SQRT_PRICE_X96_WETH = 5174885917930467233270080641214; // 0.0002344 ETH/DCA

    struct HookConfiguration {
        address poolManager;
        uint256 mintRate;
        address positionManager;
    }

    struct PoolConfiguration {
        // First token config (e.g. WETH)
        address token0;
        // Second token config (e.g. USDC)
        address token1;
    }

    struct DeployedContracts {
        SuperDCAGauge gauge;
        SuperDCAListing listing;
        SuperDCAStaking staking;
    }

    uint256 public deployerPrivateKey;
    address public deployerAddress;
    SuperDCAGauge public hook;
    SuperDCAListing public listing;
    SuperDCAStaking public staking;

    bool showDeployLogs;

    function setUp() public virtual {
        deployerPrivateKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        showDeployLogs = vm.envOr("SHOW_DEPLOY_LOGS", true);
    }

    function getHookConfiguration() public virtual returns (HookConfiguration memory);
    function getPoolConfiguration() public virtual returns (PoolConfiguration memory);

    function run() public virtual returns (DeployedContracts memory) {
        HookConfiguration memory hookConfig = getHookConfiguration();
        PoolConfiguration memory poolConfig = getPoolConfiguration();

        // Get deployer address from private key
        deployerAddress = vm.addr(deployerPrivateKey);

        // Deploy and wire contracts with the deployer key (must be the developer/admin)
        vm.startBroadcast(deployerPrivateKey);

        // Deploy hook with correct flags using HookMiner
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG
        );

        // Mine the salt that will produce a hook address with the correct flags
        bytes memory constructorArgs =
            abi.encode(hookConfig.poolManager, DCA_TOKEN, deployerAddress, IPositionManager(hookConfig.positionManager));

        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(SuperDCAGauge).creationCode, constructorArgs);

        // Deploy the hook using CREATE2 with the mined salt
        hook = new SuperDCAGauge{salt: salt}(
            IPoolManager(hookConfig.poolManager),
            DCA_TOKEN,
            deployerAddress,
            IPositionManager(hookConfig.positionManager)
        );

        require(address(hook) == hookAddress, "Hook address mismatch");

        _log("Deployed Hook:", address(hook));

        // Deploy staking (owned by deployer) and listing (admin = deployer, expected hook = deployed hook)
        staking = new SuperDCAStaking(DCA_TOKEN, hookConfig.mintRate, deployerAddress);
        listing = new SuperDCAListing(
            DCA_TOKEN,
            IPoolManager(hookConfig.poolManager),
            IPositionManager(hookConfig.positionManager),
            deployerAddress,
            IHooks(hook)
        );

        // Ownable: SuperDCAStaking.setGauge (owner = deployer)
        staking.setGauge(address(hook));
        // AccessControl: SuperDCAGauge.setStaking and setListing (DEFAULT_ADMIN_ROLE = deployer)
        hook.setStaking(address(staking));
        hook.setListing(address(listing));

        // Create pool keys for both USDC/DCA and ETH/DCA pools
        PoolKey memory usdcPoolKey = PoolKey({
            currency0: address(DCA_TOKEN) < poolConfig.token1 ? Currency.wrap(DCA_TOKEN) : Currency.wrap(poolConfig.token1),
            currency1: address(DCA_TOKEN) < poolConfig.token1 ? Currency.wrap(poolConfig.token1) : Currency.wrap(DCA_TOKEN),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(hook)
        });

        PoolKey memory ethPoolKey = PoolKey({
            currency0: address(DCA_TOKEN) < poolConfig.token0 ? Currency.wrap(DCA_TOKEN) : Currency.wrap(poolConfig.token0),
            currency1: address(DCA_TOKEN) < poolConfig.token0 ? Currency.wrap(poolConfig.token0) : Currency.wrap(DCA_TOKEN),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(hook)
        });

        // Initialize both pools
        IPoolManager(hookConfig.poolManager).initialize(usdcPoolKey, INITIAL_SQRT_PRICE_X96_USDC);
        IPoolManager(hookConfig.poolManager).initialize(ethPoolKey, INITIAL_SQRT_PRICE_X96_WETH);
        _log("Initialized USDC/DCA and ETH/DCA Pools");

        _log("DCA Token:", DCA_TOKEN);
        _log("Hook:", address(hook));
        _log("Listing:", address(listing));
        _log("Deployer:", deployerAddress);

        vm.stopBroadcast();

        return DeployedContracts({gauge: hook, listing: listing, staking: staking});
    }

    function _log(string memory message) internal view {
        if (showDeployLogs) console2.log(message);
    }

    function _log(string memory message, address addr) internal view {
        if (showDeployLogs) console2.log(message, addr);
    }
}
