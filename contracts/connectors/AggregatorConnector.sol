// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interfaces/ILiquidityConnector.sol";

struct AggregatorExtraData {
    bytes data;
}

contract AggregatorConnector is ILiquidityConnector {
    error AggregatorSwapFailed(bytes error);
    error NotImplemented();

    address public immutable router;

    constructor(address router_) {
        router = router_;
    }

    function addLiquidity(AddLiquidityData memory) external payable override {
        revert NotImplemented();
    }

    function removeLiquidity(RemoveLiquidityData memory)
        external
        pure
        override
    {
        revert NotImplemented();
    }

    function swapExactTokensForTokens(SwapData memory swapData)
        external
        payable
        override
    {
        AggregatorExtraData memory extraData =
            abi.decode(swapData.extraData, (AggregatorExtraData));
        (bool success, bytes memory error) = router.call(extraData.data);
        if (!success) {
            revert AggregatorSwapFailed(error);
        }
    }
}
