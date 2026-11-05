// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { Admin } from "contracts/base/Admin.sol";
import { IRouterAllowlist } from "contracts/interfaces/IRouterAllowlist.sol";
import {
    IWormholeCircleIntegration
} from "contracts/bridges/interfaces/IWormholeCircleIntegration.sol";
import {
    IWormholeCctpLib
} from "contracts/interfaces/libraries/IWormholeCctpLib.sol";

/// @title WormholeCctpLib
/// @notice Delegatecall-only helper that initiates a Wormhole Circle
/// Integration transfer-with-payload from a Sickle.
contract WormholeCctpLib is IWormholeCctpLib, Admin {
    bytes4 internal constant TRANSFER_TOKENS_WITH_PAYLOAD_SELECTOR = 0xa2a1f04c;

    IRouterAllowlist public immutable allowlist;
    address private immutable _self;

    constructor(
        IRouterAllowlist allowlist_,
        address admin_
    ) Admin(admin_) {
        allowlist = allowlist_;
        _self = address(this);
    }

    function transferTokensWithPayload(
        TransferArgs calldata transfer
    ) external payable returns (uint64 messageSequence) {
        if (transfer.amount == 0) revert ZeroBridgeAmount();
        if (address(this) == _self) revert NotDelegatecall();

        allowlist.requireAllowedBridge(transfer.circleIntegration);
        allowlist.requireAllowedSelector(
            transfer.circleIntegration, TRANSFER_TOKENS_WITH_PAYLOAD_SELECTOR
        );

        SafeTransferLib.safeApprove(
            transfer.token, transfer.circleIntegration, 0
        );
        SafeTransferLib.safeApprove(
            transfer.token, transfer.circleIntegration, transfer.amount
        );

        uint256 balanceBefore = IERC20(transfer.token).balanceOf(address(this));

        messageSequence = IWormholeCircleIntegration(transfer.circleIntegration)
        .transferTokensWithPayload{ value: msg.value }(
            IWormholeCircleIntegration.TransferParameters({
                    token: transfer.token,
                    amount: transfer.amount,
                    targetChain: transfer.targetChain,
                    mintRecipient: transfer.mintRecipient
                }),
            transfer.batchId,
            transfer.payload
        );

        uint256 balanceAfter = IERC20(transfer.token).balanceOf(address(this));
        if (
            balanceAfter > balanceBefore
                || balanceBefore - balanceAfter < transfer.amount
        ) {
            revert BridgeDidNotConsumeTokens();
        }

        SafeTransferLib.safeApprove(
            transfer.token, transfer.circleIntegration, 0
        );
    }
}
