// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";

import {
    INftSettingsRegistry,
    NftSettings
} from "contracts/interfaces/INftSettingsRegistry.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { IShiftMath } from "contracts/interfaces/libraries/IShiftMath.sol";

interface INftSettingsLib {
    error InvalidTokenId();

    function transferNftSettings(
        INftSettingsRegistry nftSettingsRegistry,
        INonfungiblePositionManager nftManager,
        uint256 tokenId,
        IShiftMath shiftMath,
        ConnectorRegistry connectorRegistry
    ) external;

    function setNftSettings(
        INftSettingsRegistry nftSettingsRegistry,
        INonfungiblePositionManager nftManager,
        uint256 tokenId,
        NftSettings calldata settings
    ) external;
}
