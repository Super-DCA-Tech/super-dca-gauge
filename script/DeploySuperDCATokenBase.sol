// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {SuperDCAToken} from "../src/SuperDCAToken.sol";
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

abstract contract DeploySuperDCATokenBase is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    struct TokenConfiguration {
        address defaultAdmin;
        address pauser;
        address minter;
        address upgrader;
    }

    struct HookConfiguration {
        address poolManager;
        address developerAddress;
        uint256 mintRate;
    }

    struct PoolConfiguration {
        address otherToken;
        uint24 fee;
        int24 tickSpacing;
        uint160 initialSqrtPriceX96;
    }

    uint256 public deployerPrivateKey;
    SuperDCAToken public dcaToken;
    SuperDCAGauge public hook;
    PoolKey public poolKey;

    function setUp() public virtual {
        deployerPrivateKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
    }

    function getTokenConfiguration() public virtual returns (TokenConfiguration memory);
    function getHookConfiguration() public virtual returns (HookConfiguration memory);
    function getPoolConfiguration() public virtual returns (PoolConfiguration memory);

    function run() public virtual returns (SuperDCAToken, SuperDCAGauge) {
        vm.startBroadcast(deployerPrivateKey);

        TokenConfiguration memory tokenConfig = getTokenConfiguration();
        HookConfiguration memory hookConfig = getHookConfiguration();
        PoolConfiguration memory poolConfig = getPoolConfiguration();

        // Deploy token implementation
        SuperDCAToken tokenImplementation = new SuperDCAToken();

        // Deploy proxy and initialize token
        bytes memory initData = abi.encodeCall(
            SuperDCAToken.initialize,
            (tokenConfig.defaultAdmin, tokenConfig.pauser, tokenConfig.minter, tokenConfig.upgrader)
        );

        dcaToken = SuperDCAToken(
            address(new TransparentUpgradeableProxy(address(tokenImplementation), tokenConfig.defaultAdmin, initData))
        );

        console2.log("Deployed DCA Token:", address(dcaToken));

        // Deploy hook with correct flags using HookMiner
        uint160 flags = uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);

        // Mine the salt that will produce a hook address with the correct flags
        bytes memory constructorArgs =
            abi.encode(hookConfig.poolManager, dcaToken, hookConfig.developerAddress, hookConfig.mintRate);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(SuperDCAGauge).creationCode, constructorArgs);

        // Deploy the hook using CREATE2 with the mined salt
        hook = new SuperDCAGauge{salt: salt}(
            IPoolManager(hookConfig.poolManager), dcaToken, hookConfig.developerAddress, hookConfig.mintRate
        );

        require(address(hook) == hookAddress, "Hook address mismatch");

        console2.log("Deployed Hook:", address(hook));

        // Grant minter role to hook
        bytes32 MINTER_ROLE = keccak256("MINTER_ROLE");
        dcaToken.grantRole(MINTER_ROLE, address(hook));

        console2.log("Granted MINTER_ROLE to Hook");

        // Create pool key
        address token0 = address(dcaToken) < poolConfig.otherToken ? address(dcaToken) : poolConfig.otherToken;
        address token1 = address(dcaToken) < poolConfig.otherToken ? poolConfig.otherToken : address(dcaToken);

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: poolConfig.fee,
            tickSpacing: poolConfig.tickSpacing,
            hooks: IHooks(hook)
        });

        // Initialize pool
        IPoolManager(hookConfig.poolManager).initialize(poolKey, poolConfig.initialSqrtPriceX96);

        console2.log("Initialized Pool");

        vm.stopBroadcast();

        return (dcaToken, hook);
    }
}
