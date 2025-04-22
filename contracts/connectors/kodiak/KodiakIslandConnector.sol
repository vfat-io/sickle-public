// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IKodiakIslandPool } from
    "contracts/interfaces/external/kodiak/IKodiakIslandPool.sol";
import {
    ILiquidityConnector,
    AddLiquidityParams,
    RemoveLiquidityParams,
    SwapParams
} from "contracts/interfaces/ILiquidityConnector.sol";

struct KodiakIslandMintExtraData {
    uint256 mintAmount;
}

contract KodiakIslandConnector is ILiquidityConnector {
    error NotSupported();

    function addLiquidity(
        AddLiquidityParams memory addLiquidityParams
    ) external payable override {
        KodiakIslandMintExtraData memory extraData = abi.decode(
            addLiquidityParams.extraData, (KodiakIslandMintExtraData)
        );
        IKodiakIslandPool(addLiquidityParams.lpToken).mint(
            extraData.mintAmount, address(this)
        );
    }

    function removeLiquidity(
        RemoveLiquidityParams memory removeLiquidityParams
    ) external override {
        IKodiakIslandPool(removeLiquidityParams.lpToken).burn(
            removeLiquidityParams.lpAmountIn, address(this)
        );
    }

    function swapExactTokensForTokens(
        SwapParams memory
    ) external payable override {
        revert NotSupported();
    }

    function getPoolPrice(
        address, // lpToken
        uint256, // baseTokenIndex
        uint256 // quoteTokenIndex
    ) external pure returns (uint256) {
        revert NotSupported();
    }

    function getReserves(
        address // lpToken
    ) external pure returns (uint256[] memory) {
        revert NotSupported();
    }

    function getTokens(
        address lpToken
    ) external view returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = IKodiakIslandPool(lpToken).token0();
        tokens[1] = IKodiakIslandPool(lpToken).token1();
    }
}
