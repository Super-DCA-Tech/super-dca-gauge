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

abstract contract DeployGaugeBase is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    
    // Superchain ERC20 token is the same address on all Superchain's
    address public constant DCA_TOKEN = 0xdcA49B666A770201903973733b750e001Ca23fEc;


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
        uint160 flags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);

        // Mine the salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(
            hookConfig.poolManager, DCA_TOKEN, hookConfig.developerAddress, hookConfig.mintRate
        );

        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(SuperDCAGauge).creationCode, constructorArgs);

        // Deploy the hook using CREATE2 with the mined salt
        hook = new SuperDCAGauge{salt: salt}(
            IPoolManager(hookConfig.poolManager),
            DCA_TOKEN,
            hookConfig.developerAddress,
            hookConfig.mintRate
        );

        require(address(hook) == hookAddress, "Hook address mismatch");

        console2.log("Deployed Hook:", address(hook));

        // Stake the ETH token to the hook with 600 DCA
        IERC20(DCA_TOKEN).approve(address(hook), 1000 ether);
        hook.stake(poolConfig.token0, 600 ether);

        console2.log("Staked 600 ETH to the hook");

        // Stake the USDC token to the hook with 400 DCA
        hook.stake(poolConfig.token1, 400 ether);

        console2.log("Staked 400 USDC to the hook");

        vm.stopBroadcast();

        return hook;
    }
}
