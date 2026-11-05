// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { CcipSenderBase } from "contracts/bridges/CcipSenderBase.sol";
import {
    IBridgeAmountAdapter
} from "contracts/interfaces/IBridgeAmountAdapter.sol";
import {
    BridgeDepositStrategy
} from "contracts/strategies/BridgeDepositStrategy.sol";

/// @title CcipDepositSender
/// @notice Source-side wrapper for CCIP token + destination deposit sends.
/// @dev The destination message data is consumed by `CcipDepositAdapter`.
contract CcipDepositSender is CcipSenderBase, IBridgeAmountAdapter {
    error NativeGasDropTokenConflicts();

    struct NativeGasDropTokenParams {
        address token;
        uint256 amount;
    }

    struct DepositMessage {
        address sickleOwner;
        BridgeDepositStrategy.DepositParams params;
        bytes32 intentId;
        uint256 deadline;
        bytes signature;
    }

    struct ExactAmountParams {
        address feeToken;
        bytes extraArgs;
        address sickleOwner;
        BridgeDepositStrategy.DepositParams params;
        bytes32 intentId;
        uint256 deadline;
        bytes signature;
    }

    event CcipDepositSent(
        bytes32 indexed messageId,
        address indexed caller,
        bytes32 indexed intentId,
        uint256 bridgedAmount,
        address sickleOwner
    );

    event CcipDepositWithNativeGasDropTokenSent(
        bytes32 indexed messageId,
        address indexed caller,
        bytes32 indexed intentId,
        uint256 bridgedAmount,
        address nativeGasDropToken,
        uint256 nativeGasDropAmount,
        address sickleOwner
    );

    constructor(
        address router_,
        uint64 destinationChainSelector_,
        address destinationReceiver_,
        address admin_,
        address guardian_
    )
        CcipSenderBase(
            router_,
            destinationChainSelector_,
            destinationReceiver_,
            admin_,
            guardian_
        )
    { }

    function getFee(
        address token,
        uint256 amount,
        address feeToken,
        bytes calldata extraArgs,
        address sickleOwner,
        BridgeDepositStrategy.DepositParams calldata params,
        bytes32 intentId,
        uint256 deadline,
        bytes calldata signature
    ) external view returns (uint256 fee) {
        _validateDeposit(token, sickleOwner);
        fee = _getFeeForMessage(
            token,
            amount,
            feeToken,
            extraArgs,
            abi.encode(sickleOwner, params, intentId, deadline, signature)
        );
    }

    function bridgeDeposit(
        address token,
        uint256 amount,
        address feeToken,
        bytes calldata extraArgs,
        address sickleOwner,
        BridgeDepositStrategy.DepositParams calldata params,
        bytes32 intentId,
        uint256 deadline,
        bytes calldata signature
    )
        external
        payable
        returns (bytes32 messageId, uint256 bridgedAmount, uint256 fee)
    {
        _validateDeposit(token, sickleOwner);
        (messageId, bridgedAmount, fee) = _bridgeMessage(
            token,
            amount,
            feeToken,
            extraArgs,
            abi.encode(sickleOwner, params, intentId, deadline, signature)
        );

        emit CcipDepositSent(
            messageId, msg.sender, intentId, bridgedAmount, sickleOwner
        );
    }

    function bridgeExactAmount(
        address bridgeToken,
        uint256 amount,
        bytes calldata params
    ) external payable override returns (bytes memory result) {
        ExactAmountParams memory decoded =
            abi.decode(params, (ExactAmountParams));
        _requireExactAmountNativeFee(decoded.feeToken);
        _validateDeposit(bridgeToken, decoded.sickleOwner);
        // Destination `executeDeposit` signatures bind owner/token/params,
        // not the delivered amount. `params.minAmount` is the amount guard for
        // dynamic bridge deliveries.
        (bytes32 messageId, uint256 bridgedAmount, uint256 fee) = _bridgeMessage(
            bridgeToken,
            amount,
            decoded.feeToken,
            decoded.extraArgs,
            abi.encode(
                decoded.sickleOwner,
                decoded.params,
                decoded.intentId,
                decoded.deadline,
                decoded.signature
            )
        );

        emit CcipDepositSent(
            messageId,
            msg.sender,
            decoded.intentId,
            bridgedAmount,
            decoded.sickleOwner
        );

        return abi.encode(messageId, bridgedAmount, fee);
    }

    function getFeeWithNativeGasDropToken(
        address token,
        uint256 amount,
        NativeGasDropTokenParams calldata nativeGasDrop,
        address feeToken,
        bytes calldata extraArgs,
        DepositMessage calldata deposit
    ) external view returns (uint256 fee) {
        _validateDeposit(token, deposit.sickleOwner);
        _validateNativeGasDropTokenDeposit(deposit);
        bytes memory data = _encodeDepositMessage(deposit);
        fee = _getFeeForMessage(
            token,
            amount,
            nativeGasDrop.token,
            nativeGasDrop.amount,
            feeToken,
            extraArgs,
            data
        );
    }

    function bridgeDepositWithNativeGasDropToken(
        address token,
        uint256 amount,
        NativeGasDropTokenParams calldata nativeGasDrop,
        address feeToken,
        bytes calldata extraArgs,
        DepositMessage calldata deposit
    )
        external
        payable
        returns (
            bytes32 messageId,
            uint256 bridgedAmount,
            uint256 nativeGasDropDelivered,
            uint256 fee
        )
    {
        _validateDeposit(token, deposit.sickleOwner);
        _validateNativeGasDropTokenDeposit(deposit);
        bytes memory data = _encodeDepositMessage(deposit);
        (messageId, bridgedAmount, nativeGasDropDelivered, fee) = _bridgeMessage(
            token,
            amount,
            nativeGasDrop.token,
            nativeGasDrop.amount,
            feeToken,
            extraArgs,
            data
        );

        emit CcipDepositWithNativeGasDropTokenSent(
            messageId,
            msg.sender,
            deposit.intentId,
            bridgedAmount,
            nativeGasDrop.token,
            nativeGasDropDelivered,
            deposit.sickleOwner
        );
    }

    function _encodeDepositMessage(
        DepositMessage calldata deposit
    ) internal pure returns (bytes memory) {
        return abi.encode(
            deposit.sickleOwner,
            deposit.params,
            deposit.intentId,
            deposit.deadline,
            deposit.signature
        );
    }

    function _validateDeposit(
        address token,
        address sickleOwner
    ) internal pure {
        if (token == address(0) || sickleOwner == address(0)) {
            revert ZeroAddress();
        }
    }

    function _validateNativeGasDropTokenDeposit(
        DepositMessage calldata deposit
    ) internal pure {
        if (deposit.params.nativeGasDrop > 0) {
            revert NativeGasDropTokenConflicts();
        }
    }
}
