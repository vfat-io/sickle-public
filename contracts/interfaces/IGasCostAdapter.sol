// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @title IGasCostAdapter
/// @notice Per-chain adapter for converting measured L2 gas into native cost.
interface IGasCostAdapter {
    /// @notice Returns the gas-account charge for one automation operation.
    /// @dev Batched executors must pass the per-operation payload, not
    /// `msg.data`.
    /// @param batchSize How many operations share the enclosing transaction.
    /// Components the chain levies once per transaction rather than per
    /// operation are divided by this, so a batch of N does not charge N
    /// Sickles the whole of a cost the keeper paid once. Callers must pass at
    /// least 1.
    ///
    /// @dev ABI BREAK — DEPLOY TOGETHER. This selector is `0x8a563399`; the
    /// previous two-argument `txCost(uint256,bytes)` was `0x302bf43f`. An
    /// `Automation` built against this interface reverts on EVERY
    /// gas-account charge if it is pointed at an adapter still exposing the
    /// old signature, which bricks gas-account automation on that chain.
    ///
    /// Automation and its gas-cost adapter must implement the same txCost
    /// signature when upgraded.
    function txCost(
        uint256 l2GasUsed,
        bytes calldata data,
        uint256 batchSize
    ) external view returns (uint256);
}
