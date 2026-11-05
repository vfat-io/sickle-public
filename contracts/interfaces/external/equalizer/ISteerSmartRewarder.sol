// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ISteerSmartRewarder {
    function claim(
        address[] calldata users,
        uint256[] calldata campaignIds,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;
}
