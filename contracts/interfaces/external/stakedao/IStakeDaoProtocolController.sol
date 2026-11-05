// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Stake DAO V2 ProtocolController: the registry of gauges, their
/// vaults, and each protocol's Accountant, Strategy and Locker.
interface IStakeDaoProtocolController {
    function vault(
        address gauge
    ) external view returns (address);

    function accountant(
        bytes4 protocolId
    ) external view returns (address);

    function locker(
        bytes4 protocolId
    ) external view returns (address);
}
