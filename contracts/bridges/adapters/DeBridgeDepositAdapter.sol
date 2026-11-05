// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";
import {
    BridgeDepositStrategy
} from "contracts/strategies/BridgeDepositStrategy.sol";
import {
    IDeBridgeExternalCallExecutor
} from "contracts/bridges/interfaces/IDeBridgeExternalCallExecutor.sol";

/// @title DeBridgeDepositAdapter
/// @notice Receives tokens from deBridge DLN hooks and deposits via
/// BridgeDepositStrategy. The DlnExternalCallAdapter transfers tokens
/// to this contract before calling onERC20Received.
/// @dev Hook configuration: hooks MUST be set to **atomic** so execution
/// runs within the order-fill transaction.  The recommended success mode
/// is **success-optional** with the fallback address set to the Sickle
/// owner so tokens are recoverable if the deposit callback fails.
/// If **success-required** is used instead, ensure the order's destination
/// authority supports cancellation to avoid stuck funds.
contract DeBridgeDepositAdapter is
    BridgeAdapterBase,
    IDeBridgeExternalCallExecutor
{
    BridgeDepositStrategy public immutable strategy;

    constructor(
        address strategy_,
        address admin_,
        address guardian_
    ) BridgeAdapterBase(admin_, guardian_) {
        strategy = BridgeDepositStrategy(strategy_);
    }

    /// @inheritdoc IDeBridgeExternalCallExecutor
    function onERC20Received(
        bytes32, // _orderId
        address _token,
        uint256 _transferredAmount,
        address, // _fallbackAddress
        bytes memory _payload
    ) external override returns (bool, bytes memory) {
        _onlyWhitelistedEndpoint();
        (
            address sickleOwner,
            BridgeDepositStrategy.DepositParams memory params,
            bytes32 intentId,
            uint256 deadline,
            bytes memory signature
        ) = abi.decode(
            _payload,
            (
                address,
                BridgeDepositStrategy.DepositParams,
                bytes32,
                uint256,
                bytes
            )
        );
        uint256 forwarded =
            _forwardAvailable(_token, address(strategy), _transferredAmount);
        strategy.executeDeposit(
            _token,
            forwarded,
            sickleOwner,
            params,
            intentId,
            deadline,
            signature
        );
        return (true, new bytes(0));
    }

    /// @inheritdoc IDeBridgeExternalCallExecutor
    function onEtherReceived(
        bytes32, // _orderId
        address, // _fallbackAddress
        bytes memory // _payload
    ) external payable override returns (bool, bytes memory) {
        revert("DeBridgeDepositAdapter: ETH not supported");
    }
}
