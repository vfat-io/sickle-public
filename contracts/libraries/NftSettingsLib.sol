// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import { IPositionManager } from
    "contracts/interfaces/external/uniswap/v4/IPositionManager.sol";

import {
    INftSettingsRegistry,
    NftSettings,
    NftKey
} from "contracts/interfaces/INftSettingsRegistry.sol";
import { Sickle } from "contracts/Sickle.sol";

import { INftSettingsLib } from
    "contracts/interfaces/libraries/INftSettingsLib.sol";

contract NftSettingsLib is INftSettingsLib {
    function transferNftSettings(
        INftSettingsRegistry nftSettingsRegistry,
        INonfungiblePositionManager nftManager,
        uint256 tokenId
    ) external {
        NftKey memory key = NftKey({
            sickle: Sickle(payable(address(this))),
            nftManager: nftManager,
            tokenId: tokenId
        });
        NftSettings memory settings = nftSettingsRegistry.getNftSettings(key);

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
