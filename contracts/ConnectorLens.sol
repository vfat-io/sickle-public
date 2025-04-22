// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import {
    INftLiquidityConnector,
    NftPositionInfo,
    NftPoolKey
} from "contracts/interfaces/INftLiquidityConnector.sol";

contract ConnectorLens {
    function getPositionInfo(
        ConnectorRegistry registry,
        address poolFactory,
        address nftManager,
        uint256 tokenId
    )
        external
        view
        returns (NftPositionInfo memory position, NftPoolKey memory poolKey)
    {
        address connectorAddress = registry.connectorOf(nftManager);
        INftLiquidityConnector connector =
            INftLiquidityConnector(connectorAddress);

        position = connector.positionInfo(nftManager, tokenId);
        poolKey = connector.positionPoolKey(poolFactory, nftManager, tokenId);
    }
}
