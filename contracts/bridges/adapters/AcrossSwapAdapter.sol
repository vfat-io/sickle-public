// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
import { SwapStep } from "contracts/dex/SwapTypes.sol";

import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";
import { BridgeSwapReceiver } from "contracts/bridges/BridgeSwapReceiver.sol";
import { SwapRouter } from "contracts/SwapRouter.sol";
import {
    IAcrossMessageHandler
} from "contracts/bridges/interfaces/IAcrossMessageHandler.sol";

contract AcrossSwapAdapter is BridgeAdapterBase, IAcrossMessageHandler {
    BridgeSwapReceiver public immutable receiver;

    constructor(
        address receiver_,
        address admin_,
        address guardian_
    ) BridgeAdapterBase(admin_, guardian_) {
        receiver = BridgeSwapReceiver(payable(receiver_));
    }

    function handleV3AcrossMessage(
        address tokenSent,
        uint256 amount,
        address, // relayer
        bytes memory message
    ) external override {
        _onlyWhitelistedEndpoint();
        // Payload format extended with a trailing `uint256 swapDeadline`.
        // Source-side encoders MUST set this; `type(uint256).max` opts out.
        (
            address recipient,
            SwapStep[] memory swapSteps,
            uint256 minAmountOut,
            uint256 nativeGasDrop,
            uint256 swapDeadline
        ) = abi.decode(
            message, (address, SwapStep[], uint256, uint256, uint256)
        );
        uint256 forwarded =
            _forwardAvailable(tokenSent, address(receiver), amount);
        receiver.executeSwap(
            tokenSent,
            forwarded,
            recipient,
            swapSteps,
            minAmountOut,
            nativeGasDrop,
            swapDeadline
        );
    }
}
