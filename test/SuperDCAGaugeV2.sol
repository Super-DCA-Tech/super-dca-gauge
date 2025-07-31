// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import "../src/SuperDCAGauge.sol";

/// @custom:oz-upgrades-from SuperDCAGauge
contract SuperDCAGaugeV2 is SuperDCAGauge {
    /// Runs once after the proxy is upgraded to V2
    /// @custom:oz-upgrades-validate-as-initializer
    function initializeV2() external reinitializer(2) {
        __BaseHook_init(poolManager);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
    }

    function version() external pure returns (string memory) {
        return "V2";
    }
}
