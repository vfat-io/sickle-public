// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
import { SwapStep } from "contracts/dex/SwapTypes.sol";

import { StargateAdapterBase } from "./StargateAdapterBase.sol";
import { BridgeSwapReceiver } from "contracts/bridges/BridgeSwapReceiver.sol";

/// @title StargateSwapAdapter
/// @notice Receives Stargate V2 compose callbacks and swaps tokens via
/// BridgeSwapReceiver. This path is permissionless-by-design for funds that
/// arrive through authenticated Stargate compose callbacks, subject to the
/// endpoint/pool/source-EID checks. Any whitelisted Stargate sender on a
/// whitelisted source EID may choose `recipient`, `swapSteps`, and
/// `minAmountOut` for its own bridged funds.
/// Stargate delivers assets to this contract before lzCompose() is called, and
/// the adapter requires the local balance of the compose token to be at least
/// `amountLD` before forwarding. Any extra dust is left behind on the adapter
/// instead of being mixed into the current compose delivery. For native ETH
/// pools, the adapter wraps exactly `amountLD` to WETH.
contract StargateSwapAdapter is StargateAdapterBase {
    BridgeSwapReceiver public immutable receiver;

    constructor(
        address receiver_,
        address admin_,
        address guardian_,
        address weth_
    ) StargateAdapterBase(admin_, guardian_, weth_) {
        receiver = BridgeSwapReceiver(payable(receiver_));
    }

    function _processCompose(
        address token,
        uint256 amountLD,
        bytes calldata userPayload,
        uint32,
        bytes32
    ) internal override {
        token = _prepareInboundToken(token, amountLD);

        (
            address recipient,
            SwapStep[] memory swapSteps,
            uint256 minAmountOut,
            uint256 nativeGasDrop,
            uint256 swapDeadline
        ) = abi.decode(
            userPayload, (address, SwapStep[], uint256, uint256, uint256)
        );

        uint256 forwarded =
            _forwardAvailable(token, address(receiver), amountLD);
        receiver.executeSwap(
            token,
            forwarded,
            recipient,
            swapSteps,
            minAmountOut,
            nativeGasDrop,
            swapDeadline
        );
    }
}
