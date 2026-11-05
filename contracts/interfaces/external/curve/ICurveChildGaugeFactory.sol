// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Curve sidechain factory that validates child gauges and distributes
/// bridged CRV emissions accrued by their stakers.
interface ICurveChildGaugeFactory {
    function is_valid_gauge(
        address gauge
    ) external view returns (bool);

    function minted(
        address user,
        address gauge
    ) external view returns (uint256);

    function mint(
        address gauge
    ) external;
}
