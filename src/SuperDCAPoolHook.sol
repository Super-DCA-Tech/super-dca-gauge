// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {BaseHook} from "v4-periphery/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SuperDCAToken} from "./SuperDCAToken.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/**
 * @title SuperDCAHook
 * @notice A Uniswap V4 pool hook to distribute BRAVO tokens.
 *   – Before liquidity is added: resets the LP timelock, mints tokens, donates half to the pool,
 *     and transfers half to the developer.
 *   – Before liquidity is removed: if the LP is unlocked (timelock expired), the same distribution occurs.
 *
 * Distribution logic:
 *   mintAmount = (block.timestamp - lastMinted) * mintRate;
 *   community share = mintAmount / 2  (donated via call to donate)
 *   developer share = mintAmount - community share (transferred via ERC20 transfer)
 *
 * The hook is integrated with SuperDCAToken so that its mint() and transfer() functions can be used.
 */
contract SuperDCAHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    SuperDCAToken public superDCAToken;
    address public developerAddress;
    uint256 public mintRate;
    uint256 public lastMinted;

    /**
     * @notice Sets the initial state.
     * @param _poolManager The Uniswap V4 pool manager.
     * @param _superDCAToken The deployed SuperDCAToken contract.
     * @param _developerAddress The address of the Developer.
     * @param _mintRate The number of BRAVO tokens to mint per second.
     */
    constructor(
        IPoolManager _poolManager,
        SuperDCAToken _superDCAToken,
        address _developerAddress,
        uint256 _mintRate
    ) BaseHook(_poolManager) {
        superDCAToken = _superDCAToken;
        developerAddress = _developerAddress;
        mintRate = _mintRate;
        lastMinted = block.timestamp;
    }

    /**
     * @notice Returns the hook permissions.
     * Only beforeAddLiquidity and beforeRemoveLiquidity are enabled.
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true, // Enable beforeAddLiquidity
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true, // Enable beforeRemoveLiquidity
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /**
     * @notice Internal function to calculate and distribute tokens.
     *
     * @dev It calculates the elapsed time since the last distribution, computes the mintAmount,
     * and then:
     *   - Mints the calculated amount from SuperDCAToken to this hook.
     *   - Splits the tokens into two halves:
     *       • communityShare: donated to the pool via `donate()`
     *       • developerShare: transferred to the developerAddress.
     *   - Calls `donate()` to donate the community share to the pool.
     *   - Calls `transfer()` to send the developerShare to the developerAddress.
     *   - Updates lastMinted afterward.
     */
    function _distributeTokens(PoolKey calldata key, bytes calldata hookData) internal returns (uint256) {
        uint128 liquidity = IPoolManager(msg.sender).getLiquidity(key.toId());

        // If the pool has no liquidity, return 0
        if (liquidity == 0) {
            return 0;
        }

        // Calculate the elapsed time since the last distribution
        uint256 currentTime = block.timestamp;
        uint256 elapsed = currentTime - lastMinted;

        // If no time has elapsed, return 0
        if (elapsed == 0) {
            return 0;
        }

        // Calculate the mint amount and update the lastMinted timestamp
        uint256 mintAmount = elapsed * mintRate;
        lastMinted = currentTime;

        // Mint the calculated amount from SuperDCAToken to this hook
        superDCAToken.mint(address(this), mintAmount);

        // Calculate the community and developer shares
        uint256 communityShare = superDCAToken.balanceOf(address(this)) / 2;
        uint256 developerShare = superDCAToken.balanceOf(address(this)) / 2;

        // If the mint amount is odd, add 1 to the community share
        if (mintAmount % 2 == 1) {
            communityShare += 1;
        }

        // Donate the community share to the pool
        if (address(superDCAToken) == Currency.unwrap(key.currency0)) {
            IPoolManager(msg.sender).donate(key, communityShare, 0, hookData);
        } else if (address(superDCAToken) == Currency.unwrap(key.currency1)) {
            IPoolManager(msg.sender).donate(key, 0, communityShare, hookData);
        } else {
            revert("SuperDCAToken not part of the pool");
        }

        // Transfer the developer share to the developerAddress
        superDCAToken.transfer(developerAddress, developerShare);

        return mintAmount; // Return 0 means no tokens were minted
    }

    /**
     * @dev Internal function to handle token distribution and settlement
     * @param key The pool key (identifies the pool)
     * @param hookData Arbitrary hook data
     */
    function _handleDistributionAndSettlement(PoolKey calldata key, bytes calldata hookData) internal {
        // Must sync the pool manager to the token before distributing tokens
        poolManager.sync(Currency.wrap(address(superDCAToken)));

        uint256 mintAmount = _distributeTokens(key, hookData);

        // If tokens were minted, transfer the remaining tokens to the pool manager
        // to settle the donation delta.
        if (mintAmount > 0) {
            superDCAToken.transfer(address(poolManager), superDCAToken.balanceOf(address(this)));
            poolManager.settle();
        }

        // Invariant:At this point, the hook has no tokens left.
    }

    function _beforeAddLiquidity(
        address, // sender
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata, // params
        bytes calldata hookData
    ) internal override returns (bytes4) {
        _handleDistributionAndSettlement(key, hookData);
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address, // sender
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata, // params
        bytes calldata hookData
    ) internal override returns (bytes4) {
        _handleDistributionAndSettlement(key, hookData);
        return BaseHook.beforeRemoveLiquidity.selector;
    }
}
