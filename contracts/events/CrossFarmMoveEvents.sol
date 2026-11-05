// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";

import { Sickle } from "contracts/Sickle.sol";

abstract contract CrossFarmMoveEvents {
    event SickleMovedToNft(
        Sickle indexed sickle,
        INonfungiblePositionManager indexed toNft,
        uint256 indexed toTokenId,
        address toStakingContract,
        uint256 toPoolIndex
    );

    event SickleMovedToFarm(
        Sickle indexed sickle,
        address indexed toStakingContract,
        uint256 indexed toPoolIndex
    );

    // Source-side events: a cross-farm move exits its source positions via
    // internal connector calls that emit no standard Sickle lifecycle event, so
    // these make the closed source position observable on its own. Emitted once
    // per source, mirroring the destination events above.
    event SickleMovedFromNft(
        Sickle indexed sickle,
        INonfungiblePositionManager indexed fromNft,
        uint256 indexed fromTokenId,
        address fromStakingContract,
        uint256 fromPoolIndex
    );

    event SickleMovedFromFarm(
        Sickle indexed sickle,
        address indexed fromStakingContract,
        uint256 indexed fromPoolIndex
    );
}
