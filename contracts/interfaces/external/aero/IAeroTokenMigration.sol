// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice Official liquid legacy-AERO to new-AERO converter on Base.
interface IAeroTokenMigration {
    function V2_TOKEN() external view returns (address);
    function V3_TOKEN() external view returns (address);
    function depositLiquid(
        uint256 amount,
        address recipient
    ) external payable;
}
