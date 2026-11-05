// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";

interface INftTokenIdResolver {
    error InvalidNftTokenResolver();
    error NftTokenNotFound();

    function tokenIdOf(
        Sickle sickle,
        NftPosition calldata position
    ) external view returns (uint256);
}
