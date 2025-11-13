// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

interface ISuperDCAListing {
  function isTokenListed(address token) external view returns (bool);
  function tokenOfNfp(uint256 nfpId) external view returns (address);
  function list(uint256 nftId) external;
  function setMinimumLiquidity(uint256 _minLiquidity) external;
  function collectFees(uint256 nfpId, address recipient) external;
}
