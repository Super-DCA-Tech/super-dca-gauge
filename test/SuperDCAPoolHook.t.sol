// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SuperDCAHook} from "../src/SuperDCAHook.sol";
import {SuperDCAToken} from "../src/SuperDCAToken.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract SuperDCAHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    SuperDCAHook hook;
    SuperDCAToken token;
    PoolId poolId;
    address developer = address(0xDEADBEEF);
    uint256 mintRate = 100; // SDCA tokens per second

    function setUp() public {
        // Deploy core Uniswap V4 contracts
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deploy the token implementation
        SuperDCAToken tokenImplementation = new SuperDCAToken();

        // Deploy proxy and initialize it
        bytes memory initData = abi.encodeCall(
            SuperDCAToken.initialize,
            (
                address(this), // defaultAdmin
                address(this), // pauser
                address(this), // minter
                address(this) // upgrader
            )
        );

        token = SuperDCAToken(
            address(new TransparentUpgradeableProxy(address(tokenImplementation), address(this), initData))
        );

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG) ^ (0x4242 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(manager, token, developer, mintRate);
        deployCodeTo("SuperDCAHook.sol:SuperDCAHook", constructorArgs, flags);
        hook = SuperDCAHook(flags);

        // Grant minter role to the hook address
        bytes32 MINTER_ROLE = keccak256("MINTER_ROLE");
        token.grantRole(MINTER_ROLE, address(hook));

        // Create the pool using the key from Deployers
        key = PoolKey({
            currency0: currency0,
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        // Initialize the pool
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Approve tokens for liquidity addition
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
    }

    function test_distribution_on_addLiquidity() public {
        // Add initial liquidity first
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: 1e18,
            salt: bytes32(0)
        });

        // Add the initial liquidity
        modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);

        uint256 startTime = hook.lastMinted();
        uint256 elapsed = 20;
        vm.warp(startTime + elapsed);

        // Add more liquidity which should trigger fee collection
        modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);

        // Calculate expected distribution
        uint256 mintAmount = elapsed * mintRate; // 20 * 100 = 2000
        uint256 communityShare = mintAmount / 2; // 1000
        uint256 developerShare = mintAmount / 2; // 1000

        // Add the 1 wei to community share if mintAmount is odd
        if (mintAmount % 2 == 1) {
            communityShare += 1;
        }

        // Verify distributions
        assertEq(token.balanceOf(developer), developerShare, "Developer should receive correct share");
        assertEq(hook.lastMinted(), startTime + elapsed, "Last minted timestamp should be updated");

        // Verify the donation by checking that there are fees for the pool
        // Note: Can't figure out how to check the donation fees got to the pool
        // so I will verify this on the testnet work.
        // TODO: Verify this on testnet work.
    }

    function test_distribution_on_removeLiquidity() public {
        // First add liquidity using explicit parameters
        IPoolManager.ModifyLiquidityParams memory addParams = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: 1e18,
            salt: bytes32(0)
        });
        modifyLiquidityRouter.modifyLiquidity(key, addParams, ZERO_BYTES);

        uint256 startTime = hook.lastMinted();
        uint256 elapsed = 20;
        vm.warp(startTime + elapsed);

        // Remove liquidity using explicit parameters
        IPoolManager.ModifyLiquidityParams memory removeParams = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: -1,
            salt: bytes32(0)
        });
        modifyLiquidityRouter.modifyLiquidity(key, removeParams, ZERO_BYTES);

        // Calculate expected distribution using the same logic as addLiquidity:
        // They are split evenly unless the mintAmount is odd, in which case the community gets 1 extra wei.
        uint256 mintAmount = elapsed * mintRate; // 20 * 100 = 2000
        uint256 developerShare = mintAmount / 2; // Equal split (rounded down)
        uint256 communityShare = mintAmount / 2; // Equal split (rounded down)
        if (mintAmount % 2 == 1) {
            communityShare += 1;
        }

        // Verify distributions:
        // Developer should receive their share while the pool (via manager) gets the community share.
        assertEq(token.balanceOf(developer), developerShare, "Developer should receive correct share");
        assertEq(hook.lastMinted(), startTime + elapsed, "Last minted timestamp should be updated");

        // Verify the donation by checking that there are fees for the pool
        // Note: Can't figure out how to check the donation fees got to the pool
        // so I will verify this on the testnet work.
        // TODO: Verify this on testnet work.
    }
}
