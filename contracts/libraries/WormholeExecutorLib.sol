// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { Admin } from "contracts/base/Admin.sol";
import { IRouterAllowlist } from "contracts/interfaces/IRouterAllowlist.sol";
import {
    IWormholeExecutorLib
} from "contracts/interfaces/libraries/IWormholeExecutorLib.sol";
import {
    WormholeExecutorQuote
} from "contracts/libraries/WormholeExecutorQuote.sol";

/// @notice Minimal Token Bridge surface used during the source-side
/// bridge publish. Kept inline instead of importing the repo's
/// `IWormholeTokenBridge` to avoid dragging in the destination-side
/// `IWormhole` types.
interface IWormholeTokenBridgeSend {
    function transferTokensWithPayload(
        address token,
        uint256 amount,
        uint16 recipientChain,
        bytes32 recipient,
        uint32 nonce,
        bytes memory payload
    ) external payable returns (uint64 sequence);

    function chainId() external view returns (uint16);
}

/// @notice Read-only interface the lib uses to self-query its own
/// storage from within a delegatecall. `address(this)` is the Sickle
/// during delegatecall, so any storage read must go through a regular
/// call back to the lib's own address (`_self`).
interface IWormholeExecutorLibSelf {
    function chainParamsFor(
        uint16 dstChain
    ) external view returns (WormholeExecutorQuote.ChainParams memory);
}

/// @title WormholeExecutorLib
/// @notice Delegatecall-only helper that publishes a Token Bridge
/// transfer-with-payload AND schedules an Executor relay in a single
/// Sickle multicall entry. Must be added to `SickleRegistry` as a
/// whitelisted target before it can be invoked via `Sickle.multicall`.
/// @dev Defense in depth (the on-chain `Executor` contract does NOT
/// verify the signed quote or bind payment to it, so any caller
/// controlling the `ExecutorArgs` payload could otherwise route fees
/// to an arbitrary payee):
///   1. `IRouterAllowlist` pins the Token Bridge contract + selector
///      and the Executor contract + selector.
///   2. `trustedQuoter` / `trustedPayee` are set at deploy time to the
///      official relay provider's identities (e.g. labsapis.com). The
///      signed quote is verified against these pins via
///      `WormholeExecutorQuote.verify`, so a malicious UI cannot
///      substitute an attacker key.
///   3. Per-destination `ChainParams` are admin-registered and used
///      via `WormholeExecutorQuote.verifyFee` to bind the
///      `executorFee` back to the signed EQ01 pricing. A compromised
///      relay endpoint therefore cannot pair a legitimate signed
///      quote with an inflated fee.
contract WormholeExecutorLib is IWormholeExecutorLib, Admin {
    /// @dev Selectors must match the on-chain contracts exactly.
    /// Changing these without updating the per-chain allowlist plan
    /// files will brick the path.
    bytes4 internal constant TRANSFER_TOKENS_WITH_PAYLOAD_SELECTOR =
        0xc5a5ebda;
    bytes4 internal constant REQUEST_EXECUTION_SELECTOR = 0xc513d437;

    IRouterAllowlist public immutable allowlist;
    /// @notice Official relay-provider quoter key — the EOA that signs
    /// EQ01 quotes. A UI serving a different quoter key cannot make
    /// `bridgeWithExecutor` accept the quote.
    address public immutable trustedQuoter;
    /// @notice Official relay-provider payee — the recipient of
    /// `executorFee`. Cannot be substituted even if an attacker signs
    /// a valid-looking quote with their own quoter key (that key
    /// would still fail the `trustedQuoter` pin first).
    address public immutable trustedPayee;

    /// @dev Stored at deploy time; used to enforce delegatecall-only
    /// access and to self-query storage from within delegatecall.
    address private immutable _self;

    /// @notice Admin-registered chain decimal parameters used by
    /// `WormholeExecutorQuote.verifyFee`. Keyed by Wormhole destination
    /// chain id. An uninitialized entry causes `bridgeWithExecutor` to
    /// revert with `ChainParamsNotConfigured`.
    mapping(uint16 => WormholeExecutorQuote.ChainParams) private
        _chainParamsByDstChain;

    /// EVENTS ///

    event ChainParamsSet(
        uint16 indexed dstChain,
        uint8 srcTokenDecimals,
        uint8 dstGasPriceDecimals,
        uint8 dstNativeDecimals
    );

    /// ERRORS ///

    error ZeroTrustedQuoter();
    error ZeroTrustedPayee();
    /// @notice No `ChainParams` registered for this dst chain.
    /// @dev `bridgeWithExecutor` revert — admin must call
    /// `setChainParams` before the chain pair can be used.
    error ChainParamsNotConfigured(uint16 dstChain);
    /// @notice `ChainParams` with all-zero decimals are ambiguous with
    /// "not configured", so we reject them at registration time.
    error InvalidChainParams();

    constructor(
        IRouterAllowlist allowlist_,
        address admin_,
        address trustedQuoter_,
        address trustedPayee_
    ) Admin(admin_) {
        if (trustedQuoter_ == address(0)) revert ZeroTrustedQuoter();
        if (trustedPayee_ == address(0)) revert ZeroTrustedPayee();
        allowlist = allowlist_;
        trustedQuoter = trustedQuoter_;
        trustedPayee = trustedPayee_;
        _self = address(this);
    }

    /// @notice Register the chain-param triple for a destination chain.
    /// @dev Admin-only. Called directly on the lib (NOT via a Sickle
    /// multicall), so `msg.sender` is the admin EOA/multisig and this
    /// writes to the lib's own storage slots.
    function setChainParams(
        uint16 dstChain,
        WormholeExecutorQuote.ChainParams calldata params
    ) external onlyAdmin {
        if (
            params.srcTokenDecimals == 0
                && params.dstGasPriceDecimals == 0
                && params.dstNativeDecimals == 0
        ) revert InvalidChainParams();
        _chainParamsByDstChain[dstChain] = params;
        emit ChainParamsSet(
            dstChain,
            params.srcTokenDecimals,
            params.dstGasPriceDecimals,
            params.dstNativeDecimals
        );
    }

    /// @notice View registered chain params; zero-struct if unset.
    function chainParamsFor(
        uint16 dstChain
    ) external view returns (WormholeExecutorQuote.ChainParams memory) {
        return _chainParamsByDstChain[dstChain];
    }

    /// @inheritdoc IWormholeExecutorLib
    function bridgeWithExecutor(
        BridgeArgs calldata bridge,
        ExecutorArgs calldata exec
    ) external payable {
        if (bridge.amount == 0) revert ZeroBridgeAmount();

        // 0. Delegatecall-only.
        if (address(this) == _self) revert NotDelegatecall();

        // 1. Fee accounting. Fail fast before we touch either bridge.
        uint256 required = bridge.coreFee + exec.executorFee;
        if (msg.value < required) {
            revert InsufficientNativeFee(msg.value, required);
        }

        // 2. Validate both bridges and both selectors against the
        // router allowlist. Both must be explicitly registered.
        allowlist.requireAllowedBridge(bridge.tokenBridge);
        allowlist.requireAllowedSelector(
            bridge.tokenBridge, TRANSFER_TOKENS_WITH_PAYLOAD_SELECTOR
        );
        allowlist.requireAllowedBridge(exec.executor);
        allowlist.requireAllowedSelector(
            exec.executor, REQUEST_EXECUTION_SELECTOR
        );

        // 3. Verify the signed quote header against the pinned
        // trustedQuoter / trustedPayee. Defeats a malicious UI that
        // substitutes an attacker-controlled relay provider.
        uint16 emitterChain =
            IWormholeTokenBridgeSend(bridge.tokenBridge).chainId();
        WormholeExecutorQuote.verify(
            exec.signedQuote,
            emitterChain,
            bridge.recipientChain,
            trustedQuoter,
            trustedPayee
        );

        // 4. Bind the wire `executorFee` to the signed EQ01 pricing.
        // `ChainParams` are read from the lib's own storage via an
        // external call back to `_self` — delegatecall would resolve
        // storage against the Sickle. Uninitialized params mean the
        // admin never registered this dst chain; fail closed.
        WormholeExecutorQuote.ChainParams memory chain =
            IWormholeExecutorLibSelf(_self).chainParamsFor(
                bridge.recipientChain
            );
        if (
            chain.srcTokenDecimals == 0
                && chain.dstGasPriceDecimals == 0
                && chain.dstNativeDecimals == 0
        ) revert ChainParamsNotConfigured(bridge.recipientChain);
        WormholeExecutorQuote.verifyFee(
            exec.signedQuote,
            exec.relayInstructions,
            exec.executorFee,
            chain
        );

        // 5. Approve and publish Token Bridge transfer.
        SafeTransferLib.safeApprove(bridge.token, bridge.tokenBridge, 0);
        SafeTransferLib.safeApprove(
            bridge.token, bridge.tokenBridge, bridge.amount
        );
        uint256 balanceBefore =
            IERC20(bridge.token).balanceOf(address(this));

        uint64 sequence = IWormholeTokenBridgeSend(bridge.tokenBridge)
            .transferTokensWithPayload{ value: bridge.coreFee }(
            bridge.token,
            bridge.amount,
            bridge.recipientChain,
            bridge.recipient,
            bridge.nonce,
            bridge.payload
        );

        // 6. Confirm Token Bridge actually consumed the tokens.
        uint256 balanceAfter = IERC20(bridge.token).balanceOf(address(this));
        if (balanceBefore - balanceAfter < bridge.amount) {
            revert BridgeDidNotConsumeTokens();
        }

        // 7. Revoke approval.
        SafeTransferLib.safeApprove(bridge.token, bridge.tokenBridge, 0);

        // 8. Schedule Executor relay.
        _requestExecution(bridge, exec, emitterChain, sequence);

        // 9. Refund any surplus native to the caller-chosen refund
        // address so over-payment never strands native in the Sickle.
        // Exact-payment would be hostile: gas-price drift or quote
        // rounding at the UI layer would revert the broadcast.
        uint256 surplus = msg.value - required;
        if (surplus > 0) {
            (bool refunded,) =
                exec.refundAddr.call{ value: surplus }("");
            if (!refunded) revert RefundFailed(exec.refundAddr, surplus);
        }
    }

    /// @dev Extracted to keep `bridgeWithExecutor` off the stack-too-
    /// deep cliff. `requestBytes` for a VAA v1 request is
    /// ("ERV1" | emitterChain | emitterAddress | sequence) — see
    /// `ExecutorMessages.makeVAAv1Request` in the reference repo.
    function _requestExecution(
        BridgeArgs calldata bridge,
        ExecutorArgs calldata exec,
        uint16 emitterChain,
        uint64 sequence
    ) private {
        bytes memory requestBytes = abi.encodePacked(
            bytes4("ERV1"),
            emitterChain,
            bytes32(uint256(uint160(bridge.tokenBridge))),
            sequence
        );
        bytes memory requestCalldata = abi.encodeWithSelector(
            REQUEST_EXECUTION_SELECTOR,
            bridge.recipientChain,
            bridge.recipient,
            exec.refundAddr,
            exec.signedQuote,
            requestBytes,
            exec.relayInstructions
        );
        (bool ok, bytes memory result) =
            exec.executor.call{ value: exec.executorFee }(requestCalldata);
        if (!ok) {
            if (result.length == 0) revert();
            assembly {
                revert(add(32, result), mload(result))
            }
        }
    }
}
