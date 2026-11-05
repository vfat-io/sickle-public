// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ISlipstreamFactory {
    function getPool(address token0, address token1, int24 tickSpacing) external view returns (address);
}
