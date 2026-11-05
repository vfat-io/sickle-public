// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Mints a gauge's accrued CRV to the caller.
/// @dev Ethereum exposes this as the standalone Curve Minter. Sidechain child
/// factories use `ICurveChildGaugeFactory` because their full ABI differs.
interface ICurveMinter {
    function mint(
        address gauge
    ) external;

    function minted(
        address user,
        address gauge
    ) external view returns (uint256);

    /// @notice The token this minter emits (CRV on Ethereum).
    function token() external view returns (address);

    /// @notice The GaugeController this minter checks weights against.
    function controller() external view returns (address);
}
