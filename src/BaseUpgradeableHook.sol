// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable}   from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IPoolManager}    from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks}          from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks}          from "@uniswap/v4-core/src/libraries/Hooks.sol";

/**
 * @dev  Minimal, upgrade-safe replacement for `BaseHook`.
 *       Stores `poolManager` in *storage* so its value survives proxy upgrades.
 */
abstract contract BaseHookUpgradeable is Initializable, IHooks {
    IPoolManager public poolManager;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function __BaseHook_init(IPoolManager _pm) internal onlyInitializing {
        poolManager = _pm;

        Hooks.validateHookPermissions(
            IHooks(address(this)),      // proxy address (correct one)
            getHookPermissions()        // implemented by the child hook
        );
    }

     function getHookPermissions() public pure virtual returns (Hooks.Permissions memory);

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "PoolManager only");
        _;
    }
}

