// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface ISuperDCAListing {
    function isTokenListed(address token) external view returns (bool);
    function tokenOfNfp(uint256 nfpId) external view returns (address);
    function list(uint256 nftId, PoolKey calldata key) external;
    function setMinimumLiquidity(uint256 _minLiquidity) external;
    function collectFees(uint256 nfpId, address recipient) external;
}
