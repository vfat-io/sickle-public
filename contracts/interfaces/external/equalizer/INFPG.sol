// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Interface for Equalizer NFPG (Non-Fungible Position Gauge)
interface INFPG {
    function withdraw(
        uint256 _nid
    ) external;

    function ownerOf(
        uint256 _id
    ) external view returns (address);

    function gauge() external view returns (address);

    function pool() external view returns (address);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function tickSpacing() external view returns (int24);
}
