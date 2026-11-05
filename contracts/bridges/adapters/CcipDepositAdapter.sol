// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { CcipAdapterBase } from "./CcipAdapterBase.sol";
import {
    BridgeDepositStrategy
} from "contracts/strategies/BridgeDepositStrategy.sol";
import {
    CcipClient
} from "contracts/interfaces/external/chainlink/ICCIPRouterClient.sol";

/// @title CcipDepositAdapter
/// @notice Receives Chainlink CCIP token + deposit messages and forwards them
/// into `BridgeDepositStrategy`.
contract CcipDepositAdapter is CcipAdapterBase {
    error ZeroAddress();

    event CcipDepositReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address indexed sender,
        address token,
        uint256 amount,
        address sickleOwner,
        bytes32 intentId
    );

    BridgeDepositStrategy public immutable strategy;

    constructor(
        address strategy_,
        address admin_,
        address guardian_
    ) CcipAdapterBase(admin_, guardian_) {
        if (strategy_ == address(0)) revert ZeroAddress();
        strategy = BridgeDepositStrategy(strategy_);
    }

    function ccipReceive(
        CcipClient.Any2EVMMessage calldata message
    ) external override {
        address sender = _authorizeMessage(message);
        uint256 count = message.destTokenAmounts.length;
        if (count != 1 && count != 2) {
            revert InvalidTokenAmountCount(count);
        }
        CcipClient.EVMTokenAmount calldata tokenAmount =
            message.destTokenAmounts[0];

        (
            address sickleOwner,
            BridgeDepositStrategy.DepositParams memory params,
            bytes32 intentId,
            uint256 deadline,
            bytes memory signature
        ) = abi.decode(
            message.data,
            (
                address,
                BridgeDepositStrategy.DepositParams,
                bytes32,
                uint256,
                bytes
            )
        );

        uint256 forwarded = _forwardDelivered(
            tokenAmount.token, tokenAmount.amount, address(strategy)
        );
        if (count == 1) {
            strategy.executeDeposit(
                tokenAmount.token,
                forwarded,
                sickleOwner,
                params,
                intentId,
                deadline,
                signature
            );
        } else {
            CcipClient.EVMTokenAmount calldata gasAmount =
                message.destTokenAmounts[1];
            _requireDistinctTokens(tokenAmount.token, gasAmount.token);
            uint256 forwardedGas = _forwardDelivered(
                gasAmount.token, gasAmount.amount, address(strategy)
            );
            strategy.executeDepositWithNativeGasDropToken(
                tokenAmount.token,
                forwarded,
                gasAmount.token,
                forwardedGas,
                sickleOwner,
                params,
                intentId,
                deadline,
                signature
            );
        }

        emit CcipDepositReceived(
            message.messageId,
            message.sourceChainSelector,
            sender,
            tokenAmount.token,
            forwarded,
            sickleOwner,
            intentId
        );
    }
}
