// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import {
    ILiquidityConnector,
    SwapData,
    AddLiquidityData,
    RemoveLiquidityData
} from "contracts/interfaces/ILiquidityConnector.sol";
import { SwapLib } from "contracts/libraries/SwapLib.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { DelegateModule } from "contracts/modules/DelegateModule.sol";

struct ZapInData {
    SwapData[] swaps;
    AddLiquidityData addLiquidityData;
}

struct ZapOutData {
    RemoveLiquidityData removeLiquidityData;
    SwapData[] swaps;
}

contract ZapLib is DelegateModule {
    error LiquidityAmountError(); // 0x4d0ab6b4

    SwapLib public immutable swapLib;
    ConnectorRegistry public immutable connectorRegistry;

    constructor(ConnectorRegistry connectorRegistry_, SwapLib swapLib_) {
        connectorRegistry = connectorRegistry_;
        swapLib = swapLib_;
    }

    function zapIn(ZapInData memory zapData) external payable {
        uint256 swapDataLength = zapData.swaps.length;
        for (uint256 i; i < swapDataLength;) {
            _delegateTo(
                address(swapLib),
                abi.encodeCall(SwapLib.swap, (zapData.swaps[i]))
            );
            unchecked {
                i++;
            }
        }

        if (zapData.addLiquidityData.lpToken == address(0)) {
            return;
        }

        bool atLeastOneNonZero = false;

        AddLiquidityData memory addLiquidityData = zapData.addLiquidityData;
        uint256 addLiquidityDataTokensLength = addLiquidityData.tokens.length;
        for (uint256 i; i < addLiquidityDataTokensLength; i++) {
            if (addLiquidityData.tokens[i] == address(0)) {
                continue;
            }
            if (addLiquidityData.desiredAmounts[i] == 0) {
                addLiquidityData.desiredAmounts[i] =
                    IERC20(addLiquidityData.tokens[i]).balanceOf(address(this));
            }
            if (addLiquidityData.desiredAmounts[i] > 0) {
                atLeastOneNonZero = true;
                // In case there is USDT or similar dust approval, revoke it
                SafeTransferLib.safeApprove(
                    addLiquidityData.tokens[i], addLiquidityData.router, 0
                );
                SafeTransferLib.safeApprove(
                    addLiquidityData.tokens[i],
                    addLiquidityData.router,
                    addLiquidityData.desiredAmounts[i]
                );
            }
        }

        if (!atLeastOneNonZero) {
            revert LiquidityAmountError();
        }

        address routerConnector =
            connectorRegistry.connectorOf(addLiquidityData.router);

        _delegateTo(
            routerConnector,
            abi.encodeCall(ILiquidityConnector.addLiquidity, (addLiquidityData))
        );

        for (uint256 i; i < addLiquidityDataTokensLength;) {
            if (addLiquidityData.tokens[i] != address(0)) {
                // Revoke any dust approval in case the amount was estimated
                SafeTransferLib.safeApprove(
                    addLiquidityData.tokens[i], addLiquidityData.router, 0
                );
            }
            unchecked {
                i++;
            }
        }
    }

    function zapOut(ZapOutData memory zapData) external {
        if (zapData.removeLiquidityData.lpToken != address(0)) {
            if (zapData.removeLiquidityData.lpAmountIn > 0) {
                SafeTransferLib.safeApprove(
                    zapData.removeLiquidityData.lpToken,
                    zapData.removeLiquidityData.router,
                    zapData.removeLiquidityData.lpAmountIn
                );
            }
            address routerConnector = connectorRegistry.connectorOf(
                zapData.removeLiquidityData.router
            );
            _delegateTo(
                address(routerConnector),
                abi.encodeCall(
                    ILiquidityConnector.removeLiquidity,
                    zapData.removeLiquidityData
                )
            );
        }

        uint256 swapDataLength = zapData.swaps.length;
        for (uint256 i; i < swapDataLength;) {
            _delegateTo(
                address(swapLib),
                abi.encodeCall(SwapLib.swap, (zapData.swaps[i]))
            );
            unchecked {
                i++;
            }
        }
    }
}
