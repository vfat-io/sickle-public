// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
import { SwapStep } from "contracts/dex/SwapTypes.sol";

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { WormholeAdapterBase } from "./WormholeAdapterBase.sol";
import { BridgeSwapReceiver } from "contracts/bridges/BridgeSwapReceiver.sol";
import { SwapRouter } from "contracts/SwapRouter.sol";

/// @title WormholeSwapAdapter
/// @notice Redeems Wormhole Token Bridge transfer-with-payload VAAs and
/// executes a swap via BridgeSwapReceiver.
/// @dev See WormholeDepositAdapter for the Executor Relay security model.
contract WormholeSwapAdapter is WormholeAdapterBase {
    BridgeSwapReceiver public immutable receiver;

    constructor(
        address receiver_,
        address tokenBridge_,
        address admin_,
        address guardian_
    ) WormholeAdapterBase(tokenBridge_, admin_, guardian_) {
        receiver = BridgeSwapReceiver(payable(receiver_));
    }

    /// @notice Redeem a Wormhole transfer-with-payload VAA and execute a
    /// swap.
    /// @param encodedVAA Signed Wormhole VAA (Token Bridge type 3 transfer
    /// whose `to` field is this adapter's address)
    function executeVAAv1(
        bytes calldata encodedVAA
    ) external payable {
        (address localToken, uint256 received, bytes memory transferMsg,,) =
            _redeemTransfer(encodedVAA);

        (
            address recipient,
            SwapStep[] memory swapSteps,
            uint256 minAmountOut,
            uint256 nativeGasDrop,
            uint256 swapDeadline
        ) = abi.decode(
            transferMsg, (address, SwapStep[], uint256, uint256, uint256)
        );

        if (msg.value > 0) {
            SafeTransferLib.safeTransferETH(recipient, msg.value);
        }

        SafeTransferLib.safeTransfer(localToken, address(receiver), received);
        receiver.executeSwap(
            localToken,
            received,
            recipient,
            swapSteps,
            minAmountOut,
            nativeGasDrop,
            swapDeadline
        );
    }
}
