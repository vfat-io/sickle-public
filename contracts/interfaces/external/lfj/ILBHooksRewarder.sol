// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface ILBHooksRewarder {
    function getLBPair() external view returns (address);
    function getRewardToken() external view returns (address);
    function getPendingRewards(
        address user,
        uint256[] calldata ids
    ) external view returns (uint256);
    function claim(
        address user,
        uint256[] calldata ids
    ) external;
}

interface ILBPairHooks {
    function getLBHooksParameters() external view returns (bytes32);
}
