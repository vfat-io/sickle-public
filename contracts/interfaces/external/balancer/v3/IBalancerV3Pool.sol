// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice Balancer V3 `PoolSwapParams` (`kind`: `EXACT_IN = 0`).
struct BalancerV3PoolSwapParams {
    uint8 kind;
    uint256 amountGivenScaled18;
    uint256[] balancesScaled18;
    uint256 indexIn;
    uint256 indexOut;
    address router;
    bytes userData;
}

/// @notice Pool-math views of a Balancer V3 pool. `onSwap` is a fee-free
/// `view` on both WeightedPool and StablePool; the Vault applies fees.
interface IBalancerV3Pool {
    function onSwap(
        BalancerV3PoolSwapParams memory params
    ) external view returns (uint256 amountCalculatedScaled18);

    /// @dev WeightedPool only.
    function getNormalizedWeights() external view returns (uint256[] memory);
}
