// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice Solidly-style pair factory lookup used to prove a pool-direct
/// swap target really was deployed by an allow-listed factory for the
/// declared `(tokenA, tokenB, stable)` key.
interface ISolidlyPairFactory {
    function getPair(
        address tokenA,
        address tokenB,
        bool stable
    ) external view returns (address pair);

    function isPair(
        address pair
    ) external view returns (bool);
}
