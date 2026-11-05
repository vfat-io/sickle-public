// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    INonfungiblePositionManager
} from "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import {
    IUniswapV3Pool
} from "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";
import { SickleFactory } from "contracts/SickleFactory.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import {
    INftSettingsRegistry
} from "contracts/interfaces/INftSettingsRegistry.sol";
import { NftFarmStrategy } from "contracts/strategies/NftFarmStrategy.sol";

/// @notice NftFarmStrategy deployment lane for owner-accounted ERC-6909 LP
/// positions. Its ABI and settings model intentionally match NftFarmStrategy;
/// the isolated deployment is bound to Erc6909ShiftMath rather than mutating
/// an existing NftFarmStrategy's ShiftMath immutable.
contract Erc6909FarmStrategy is NftFarmStrategy {
    constructor(
        SickleFactory factory,
        ConnectorRegistry connectorRegistry,
        INftSettingsRegistry nftSettingsRegistry,
        NftFarmStrategy.Libraries memory libraries
    )
        NftFarmStrategy(
            factory, connectorRegistry, nftSettingsRegistry, libraries
        )
    { }

    /// @dev An ERC-6909 range id is only meaningful to the ledger that issued
    /// it (for Fables, the hook), so the fee is read from `nft`. `pool` stays
    /// the V4 PoolManager that NftSettings.pool stores and Erc6909ShiftMath
    /// binds rebalanceFor to, and is not a ledger.
    function _getRebalanceFee(
        INonfungiblePositionManager nft,
        IUniswapV3Pool, // pool
        uint256 tokenId
    ) internal view override returns (bytes4) {
        return
            super._getRebalanceFee(nft, IUniswapV3Pool(address(nft)), tokenId);
    }
}
