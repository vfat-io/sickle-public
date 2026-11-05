// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { StargateAdapterBase } from "./StargateAdapterBase.sol";
import {
    BridgeDepositStrategy
} from "contracts/strategies/BridgeDepositStrategy.sol";

/// @title StargateDepositAdapter
/// @notice Receives Stargate V2 compose callbacks and deposits into farms
/// via BridgeDepositStrategy. Stargate delivers assets to this contract before
/// lzCompose() is called, and the adapter requires the local balance of the
/// compose token to be at least `amountLD` before forwarding. Any extra dust is
/// left behind on the adapter instead of being mixed into the current compose
/// delivery. For native ETH pools (poolTokens == address(0)), the adapter wraps
/// exactly `amountLD` to WETH.
/// @dev The adapter resolves an authenticated `originator` for the signed
/// intent. For direct sends the originator binds to the LZ compose context
/// `(srcEid, composeFrom)`. For sends routed through a registered hub, the
/// originator is taken from a leading `bytes32` field of the user payload
/// (the hub puts its own first-hop-authenticated source there).
contract StargateDepositAdapter is StargateAdapterBase {
    event TrustedHubComposeFromSet(
        uint32 indexed srcEid, bytes32 indexed composeFrom, bool trusted
    );

    BridgeDepositStrategy public immutable strategy;

    /// @notice Per-source-EID set of `composeFrom` values that the adapter
    /// treats as trusted hub receivers. When a compose arrives with one of
    /// these, the originator is taken from the user payload rather than from
    /// the (shared) LZ composeFrom.
    mapping(uint32 srcEid => mapping(bytes32 composeFrom => bool))
        public trustedHubComposeFrom;

    constructor(
        address strategy_,
        address admin_,
        address guardian_,
        address weth_
    ) StargateAdapterBase(admin_, guardian_, weth_) {
        strategy = BridgeDepositStrategy(strategy_);
    }

    function setTrustedHubComposeFrom(
        uint32 srcEid,
        bytes32 composeFrom,
        bool trusted
    ) external onlyAdmin {
        trustedHubComposeFrom[srcEid][composeFrom] = trusted;
        emit TrustedHubComposeFromSet(srcEid, composeFrom, trusted);
    }

    function _processCompose(
        address token,
        uint256 amountLD,
        bytes calldata userPayload,
        uint32 srcEid,
        bytes32 composeFrom
    ) internal override {
        token = _prepareInboundToken(token, amountLD);

        bytes32 originator;
        bytes memory innerPayload;
        if (trustedHubComposeFrom[srcEid][composeFrom]) {
            // Hub-routed: hub embedded the authenticated originator at
            // the head of the payload.
            (originator, innerPayload) =
                abi.decode(userPayload, (bytes32, bytes));
        } else {
            // Direct send: bind to the LZ compose context.
            originator = keccak256(abi.encode(srcEid, composeFrom));
            innerPayload = userPayload;
        }

        (
            address sickleOwner,
            BridgeDepositStrategy.DepositParams memory params,
            bytes32 intentId,
            uint256 deadline,
            bytes memory signature
        ) = abi.decode(
            innerPayload,
            (
                address,
                BridgeDepositStrategy.DepositParams,
                bytes32,
                uint256,
                bytes
            )
        );

        uint256 forwarded =
            _forwardAvailable(token, address(strategy), amountLD);
        strategy.executeStargateDeposit(
            token,
            forwarded,
            sickleOwner,
            params,
            intentId,
            deadline,
            originator,
            signature
        );
    }
}
