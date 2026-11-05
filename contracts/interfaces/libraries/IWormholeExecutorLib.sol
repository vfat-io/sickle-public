// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IWormholeExecutorLib
/// @notice Source-side helper that combines a Wormhole Token Bridge
/// `transferTokensWithPayload` publish with a Wormhole Executor
/// `requestExecution` in a single delegatecall from a Sickle. Splits
/// `msg.value` between the Token Bridge core message fee and the
/// off-chain quoted Executor relay fee.
/// @dev Destination delivery is performed by an off-chain relay provider
/// which ultimately calls `executeVAAv1(bytes)` on the destination
/// adapter (see `IVaaV1Receiver` in the Executor reference repo). No
/// destination-side contract change is required — the current
/// permissionless-redeem adapters are already the Executor receiver.
interface IWormholeExecutorLib {
    error ZeroBridgeAmount();
    error NotDelegatecall();
    error BridgeDidNotConsumeTokens();
    /// @notice msg.value on entry did not cover coreFee + executorFee.
    error InsufficientNativeFee(uint256 provided, uint256 required);
    /// @notice Refund of surplus native to `refundAddr` reverted.
    error RefundFailed(address to, uint256 amount);

    struct BridgeArgs {
        /// @dev Wormhole Token Bridge contract on source chain.
        address tokenBridge;
        /// @dev ERC20 being bridged. `address(0)` is NOT supported for
        /// this flow — Token Bridge does not take native; wrap to WETH
        /// upstream.
        address token;
        /// @dev Amount of `token` to bridge. Must be > 0.
        uint256 amount;
        /// @dev Native fee forwarded to `transferTokensWithPayload` (the
        /// Wormhole Core publish fee). Typically 0 on most EVM chains
        /// but non-zero on some.
        uint256 coreFee;
        /// @dev Wormhole chain ID of the destination (NOT an EVM chain
        /// ID).
        uint16 recipientChain;
        /// @dev Destination adapter / receiver, bytes32-padded.
        bytes32 recipient;
        /// @dev Wormhole message nonce (can be block.timestamp-derived
        /// or any caller-chosen value).
        uint32 nonce;
        /// @dev Application-layer payload decoded by the destination
        /// adapter (e.g. the encoded BridgeDepositStrategy intent).
        bytes payload;
    }

    struct ExecutorArgs {
        /// @dev Per-chain Wormhole Executor contract on source.
        address executor;
        /// @dev Address to refund source-chain native if the quote
        /// expires or the request cannot be executed. Should be the
        /// user EOA, NOT the Sickle — otherwise refunds trap in the
        /// Sickle.
        address refundAddr;
        /// @dev Native fee forwarded to `requestExecution`. Must match
        /// the off-chain-quoted `estimatedCost`. Paid to the payee
        /// address encoded inside `signedQuote`.
        uint256 executorFee;
        /// @dev Off-chain-fetched signed quote (bytes returned by the
        /// relay provider's POST /v0/quote endpoint).
        bytes signedQuote;
        /// @dev Encoded relay instructions — gas limit at target, any
        /// drop-off. See `RelayInstructions` library in the reference
        /// Executor repo.
        bytes relayInstructions;
    }

    /// @notice Bridge tokens via Wormhole Token Bridge and schedule
    /// automated destination delivery via Wormhole Executor.
    /// @dev Must be delegatecalled from a Sickle. Reverts if
    /// `msg.value < bridge.coreFee + exec.executorFee`.
    function bridgeWithExecutor(
        BridgeArgs calldata bridge,
        ExecutorArgs calldata exec
    ) external payable;
}
