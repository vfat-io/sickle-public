// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IKatanaStakingRouter {
    function executePreCommit(
        address user
    ) external;

    function batchExecutePreCommit(
        address[] calldata users
    ) external;

    function katToken() external view returns (address);

    function avKatVault() external view returns (address);
}
