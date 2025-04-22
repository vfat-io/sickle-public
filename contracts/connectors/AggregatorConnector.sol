// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    ILiquidityConnector,
    AddLiquidityParams,
    RemoveLiquidityParams,
    SwapParams
} from "contracts/interfaces/ILiquidityConnector.sol";

struct AggregatorExtraData {
    bytes data;
}

contract AggregatorConnector is ILiquidityConnector {
    error AggregatorSwapFailed(bytes error);
    error NotImplemented();

    address public immutable router;

    constructor(
        address router_
    ) {
        router = router_;
    }

    function addLiquidity(
        AddLiquidityParams memory
    ) external payable override {
        revert NotImplemented();
    }

    function removeLiquidity(
        RemoveLiquidityParams memory
    ) external pure override {
        revert NotImplemented();
    }

    function swapExactTokensForTokens(
        SwapParams memory swap
    ) external payable override {
        AggregatorExtraData memory extraData =
            abi.decode(swap.extraData, (AggregatorExtraData));
        (bool success, bytes memory error) = router.call(extraData.data);
        if (!success) {
            revert AggregatorSwapFailed(error);
        }
    }

    function getPoolPrice(
        address, // lpToken
        uint256, // baseTokenIndex
        uint256 // quoteTokenIndex
    ) external pure override returns (uint256) {
        revert NotImplemented();
    }

    function getReserves(
        address // lpToken
    ) external pure override returns (uint256[] memory) {
        revert NotImplemented();
    }

    function getTokens(
        address // lpToken
    ) external pure override returns (address[] memory) {
        revert NotImplemented();
    }
}
