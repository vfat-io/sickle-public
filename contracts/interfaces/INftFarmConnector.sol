// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";

interface INftFarmConnector {
    function depositExistingNft(
        NftPosition calldata position,
        bytes calldata extraData
    ) external;

    function withdrawNft(
        NftPosition calldata position,
        bytes calldata extraData
    ) external;

    function claim(
        NftPosition calldata position,
        address[] memory rewardTokens,
        uint128 maxAmount0, // For collecting
        uint128 maxAmount1,
        bytes calldata extraData
    ) external;

    function earned(
        address user,
        NftPosition calldata position,
        address[] memory rewardTokens
    ) external view returns (uint256[] memory);

    function isStaked(
        address user,
        NftPosition calldata position
    ) external view returns (bool);
}
