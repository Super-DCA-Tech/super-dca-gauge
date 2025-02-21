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
        // First token config (e.g. WETH)
        address token0;
        // Second token config (e.g. USDC)
        address token1;
    }

    uint256 public deployerPrivateKey;
    SuperDCAToken public dcaToken;
    SuperDCAGauge public hook;

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
        bytes32 minterRole = keccak256("MINTER_ROLE");
        dcaToken.grantRole(minterRole, address(hook));

        console2.log("Granted MINTER_ROLE to Hook");

        // Mint 10_000 to the deployer
        dcaToken.mint(vm.addr(deployerPrivateKey), 10_000 ether);

        // Stake the ETH token to the hook with 600 DCA
        dcaToken.approve(address(hook), 1000 ether);
        hook.stake(poolConfig.token0, 600 ether);

        console2.log("Staked 600 ETH to the hook");

        // Stake the USDC token to the hook with 400 DCA
        hook.stake(poolConfig.token1, 400 ether);

        console2.log("Staked 400 USDC to the hook");

        vm.stopBroadcast();

        return (dcaToken, hook);
    }
}
