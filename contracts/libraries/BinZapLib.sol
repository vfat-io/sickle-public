// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IBinZapLib } from "contracts/interfaces/libraries/IBinZapLib.sol";
import {
    IBinLiquidityConnector
} from "contracts/interfaces/IBinLiquidityConnector.sol";
import { ISwapLib } from "contracts/interfaces/libraries/ISwapLib.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { DelegateModule } from "contracts/modules/DelegateModule.sol";
import {
    BinZapOut,
    BinAddLiquidity,
    BinRemoveLiquidity
} from "contracts/structs/BinFarmStrategyStructs.sol";

contract BinZapLib is DelegateModule, IBinZapLib {
    error LiquidityAmountError();
    error ArrayLengthMismatch();
    error UnexpectedBinIds();

    ISwapLib public immutable swapLib;
    ConnectorRegistry public immutable connectorRegistry;

    constructor(
        ConnectorRegistry connectorRegistry_,
        ISwapLib swapLib_
    ) {
        connectorRegistry = connectorRegistry_;
        swapLib = swapLib_;
    }

    /// @inheritdoc IBinZapLib
    function addLiquidityChecked(
        BinAddLiquidity memory params,
        uint256[] memory expectedBinIds
    ) external payable override {
        _assertIds(
            expectedBinIds, _idsAt(params.activeIdDesired, params.deltaIds)
        );
        uint256[] memory currentIds =
            _idsAt(params.lbPair.getActiveId(), params.deltaIds);
        _assertIds(_addLiquidity(params), currentIds);
    }

    function _addLiquidity(
        BinAddLiquidity memory addLiquidityParams
    ) private returns (uint256[] memory depositIds) {
        // Use current balance if amount is 0
        if (addLiquidityParams.amountX == 0) {
            addLiquidityParams.amountX =
                IERC20(addLiquidityParams.tokenX).balanceOf(address(this));
        }
        if (addLiquidityParams.amountY == 0) {
            addLiquidityParams.amountY =
                IERC20(addLiquidityParams.tokenY).balanceOf(address(this));
        }

        address lbPairAddress = address(addLiquidityParams.lbPair);
        if (addLiquidityParams.amountX == 0 && addLiquidityParams.amountY == 0)
        {
            revert LiquidityAmountError();
        }

        // Get connector and add liquidity
        address binConnector = connectorRegistry.connectorOf(lbPairAddress);

        bytes memory result = _delegateToConnector(
            binConnector,
            abi.encodeCall(
                IBinLiquidityConnector.addLiquidity, (addLiquidityParams)
            )
        );

        (depositIds,) = abi.decode(result, (uint256[], uint256[]));
    }

    function _idsAt(
        uint256 activeId,
        int256[] memory deltaIds
    ) private pure returns (uint256[] memory ids) {
        if (activeId > type(uint24).max) revert UnexpectedBinIds();
        ids = new uint256[](deltaIds.length);
        for (uint256 i; i < deltaIds.length; ++i) {
            int256 id = int256(activeId) + deltaIds[i];
            if (id < 0 || id > int256(uint256(type(uint24).max))) {
                revert UnexpectedBinIds();
            }
            ids[i] = uint256(id);
        }
    }

    function _assertIds(
        uint256[] memory actual,
        uint256[] memory expected
    ) private pure {
        if (actual.length != expected.length) revert UnexpectedBinIds();
        for (uint256 i; i < actual.length; ++i) {
            if (
                actual[i] != expected[i]
                    || (i > 0 && actual[i] <= actual[i - 1])
            ) revert UnexpectedBinIds();
        }
    }

    /// @inheritdoc IBinZapLib
    function zapOut(
        BinZapOut memory zap
    ) external override returns (uint256 amountX, uint256 amountY) {
        BinRemoveLiquidity memory removeLiquidityParams =
        zap.removeLiquidityParams;

        if (
            removeLiquidityParams.ids.length
                != removeLiquidityParams.amounts.length
        ) {
            revert ArrayLengthMismatch();
        }

        address lbPairAddress = address(removeLiquidityParams.lbPair);
        address binConnector = connectorRegistry.connectorOf(lbPairAddress);

        bytes memory result = _delegateToConnector(
            binConnector,
            abi.encodeCall(
                IBinLiquidityConnector.removeLiquidity, removeLiquidityParams
            )
        );

        (amountX, amountY) = abi.decode(result, (uint256, uint256));

        // Execute swaps
        uint256 swapDataLength = zap.swaps.length;
        for (uint256 i; i < swapDataLength;) {
            _delegateTo(
                address(swapLib), abi.encodeCall(ISwapLib.swap, (zap.swaps[i]))
            );
            unchecked {
                i++;
            }
        }
    }
}
