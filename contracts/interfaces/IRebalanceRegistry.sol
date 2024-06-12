// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IUniswapV3Pool } from
    "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";
import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import { Sickle } from "contracts/Sickle.sol";

struct RebalanceKey {
    Sickle sickle;
    INonfungiblePositionManager nftManager;
    uint256 tokenId;
}

struct RebalanceConfig {
    int24 tickLow;
    int24 tickHigh;
    uint256 slippageBP;
    int24 minTickLow;
    int24 maxTickHigh;
}

struct NftInfo {
    IUniswapV3Pool pool;
    INonfungiblePositionManager nftManager;
    uint256 tokenId;
}

interface IRebalanceRegistry {
    function getRebalanceConfig(RebalanceKey calldata key)
        external
        view
        returns (RebalanceConfig memory);

    function resetRebalanceConfig(
        RebalanceKey calldata oldKey,
        RebalanceKey calldata newKey,
        RebalanceConfig calldata config
    ) external;
}
