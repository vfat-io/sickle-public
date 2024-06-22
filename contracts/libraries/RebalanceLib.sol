// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    IRebalanceRegistry,
    RebalanceConfig,
    RebalanceKey,
    NftInfo
} from "contracts/interfaces/IRebalanceRegistry.sol";
import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import { Sickle } from "contracts/Sickle.sol";

contract RebalanceLib {
    error TokenIdUnchanged();

    function resetRebalanceConfig(
        IRebalanceRegistry rebalanceRegistry,
        NftInfo calldata nftInfo
    ) external {
        RebalanceKey memory key = RebalanceKey(
            Sickle(payable(address(this))), nftInfo.nftManager, nftInfo.tokenId
        );
        RebalanceConfig memory config =
            rebalanceRegistry.getRebalanceConfig(key);

        INonfungiblePositionManager nftManager =
            INonfungiblePositionManager(key.nftManager);

        uint256 newTokenId = nftManager.tokenOfOwnerByIndex(
            address(this), nftManager.balanceOf(address(this)) - 1
        );

        if (newTokenId == key.tokenId) {
            revert TokenIdUnchanged();
        }

        (,,,,, int24 tickLower, int24 tickUpper,,,,,) =
            nftManager.positions(newTokenId);

        int24 midTick = (tickUpper + tickLower) / 2;

        int24 midRange = (config.tickHigh - config.tickLow) / 2;

        config.tickLow = midTick - midRange;
        config.tickHigh = midTick + midRange;

        RebalanceKey memory newKey =
            RebalanceKey(key.sickle, key.nftManager, newTokenId);

        rebalanceRegistry.resetRebalanceConfig(key, newKey, config);
    }
}
