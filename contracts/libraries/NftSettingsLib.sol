// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";

import {
    INftSettingsRegistry,
    NftSettings,
    NftKey
} from "contracts/interfaces/INftSettingsRegistry.sol";
import {
    INftLiquidityConnector
} from "contracts/interfaces/INftLiquidityConnector.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { Sickle } from "contracts/Sickle.sol";

import { INftSettingsLib } from
    "contracts/interfaces/libraries/INftSettingsLib.sol";
import { IShiftMath } from "contracts/interfaces/libraries/IShiftMath.sol";

contract NftSettingsLib is INftSettingsLib {
    function transferNftSettings(
        INftSettingsRegistry nftSettingsRegistry,
        INonfungiblePositionManager nftManager,
        uint256 tokenId,
        IShiftMath shiftMath,
        ConnectorRegistry connectorRegistry
    ) external {
        NftKey memory key = NftKey({
            sickle: Sickle(payable(address(this))),
            nftManager: nftManager,
            tokenId: tokenId
        });
        NftSettings memory settings = nftSettingsRegistry.getNftSettings(key);

        if (settings.autoExit || settings.autoRebalance) {
            INftLiquidityConnector connector = INftLiquidityConnector(
                connectorRegistry.connectorOf(address(nftManager))
            );
            uint256 newTokenId =
                connector.getTokenId(address(nftManager), address(this));
            shiftMath.postMintRebalanceChecks(
                key, settings, newTokenId, false, 0, 0, connectorRegistry
            );
        }

        nftSettingsRegistry.transferNftSettings(key, settings);
    }

    function setNftSettings(
        INftSettingsRegistry nftSettingsRegistry,
        INonfungiblePositionManager nftManager,
        uint256 tokenId,
        NftSettings calldata settings
    ) external {
        NftKey memory key = NftKey({
            sickle: Sickle(payable(address(this))),
            nftManager: nftManager,
            tokenId: tokenId
        });
        nftSettingsRegistry.setNftSettings(key, settings);
    }
}
