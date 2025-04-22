// SPDX-License-Identifier: MIT
pragma solidity >=0.8.9;

/// @title Interface of the Masterchef contract
/// @author vfat.tools
/// @notice Basic Masterchef interface
interface IMerchantMoeMasterchef {
    function deposit(uint256 _pid, uint256 _amount) external;

    function withdraw(uint256 _pid, uint256 _amount) external;

    function emergencyWithdraw(
        uint256 _pid
    ) external;

    function getDeposit(
        uint256 pid,
        address account
    ) external view returns (uint256);

    function getPendingRewards(
        address user,
        uint256[] calldata pids
    )
        external
        view
        returns (uint256[] memory, address[] memory, uint256[] memory);
}
