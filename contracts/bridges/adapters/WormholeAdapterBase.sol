// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";
import {
    IWormholeTokenBridge,
    IWormhole
} from "contracts/bridges/interfaces/IWormholeTokenBridge.sol";

/// @title WormholeAdapterBase
/// @notice Shared base for Wormhole Executor Relay adapters.
/// @dev Handles Wormhole message parsing, Token Bridge redemption, and
/// balance-delta accounting so derived adapters only forward tokens that were
/// actually redeemed by the current VAA.
/// @dev Security model (no caller authentication required):
///   1. Wormhole Core parses the VAA so the adapter can resolve the token for
///      balance accounting
///   2. Token Bridge verifies the VAA and marks redeemed VAAs
///   3. Balance-before/after isolation forwards only newly redeemed tokens,
///      leaving residual adapter balances untouched
abstract contract WormholeAdapterBase is BridgeAdapterBase {
    /// @notice Thrown when a bridged foreign token has not been attested on the
    /// local Token Bridge.
    error TokenNotAttested();

    IWormholeTokenBridge public immutable tokenBridge;

    constructor(
        address tokenBridge_,
        address admin_,
        address guardian_
    ) BridgeAdapterBase(admin_, guardian_) {
        tokenBridge = IWormholeTokenBridge(tokenBridge_);
    }

    /// @dev Redeems a transfer-with-payload VAA.
    /// Parses the Wormhole payload to resolve the local token, snapshots the
    /// adapter balance before redemption, then returns the redeemed balance
    /// delta together with the decoded application payload.
    function _redeemTransfer(
        bytes calldata encodedVAA
    )
        internal
        returns (
            address localToken,
            uint256 received,
            bytes memory transferMsg,
            uint16 emitterChainId,
            bytes32 emitterAddress
        )
    {
        IWormhole.VM memory parsedMessage =
            tokenBridge.wormhole().parseVM(encodedVAA);
        IWormholeTokenBridge.TransferWithPayload memory parsedTransfer =
            tokenBridge.parseTransferWithPayload(parsedMessage.payload);
        localToken = verifyTokenAddress(parsedTransfer);

        // Resolve the token before redemption so we can isolate the balance
        // delta.
        uint256 balanceBefore = _tokenBalance(localToken);

        // Redeem the transfer and materialize the bridged funds in this
        // adapter.
        bytes memory transferPayload =
            tokenBridge.completeTransferWithPayload(encodedVAA);
        IWormholeTokenBridge.TransferWithPayload memory transfer =
            tokenBridge.parseTransferWithPayload(transferPayload);
        transferMsg = transfer.payload;

        // Only count tokens received in this redemption.
        received = _tokenBalance(localToken) - balanceBefore;

        // Expose the authenticated emitter so route adapters can bind a
        // downstream originator.
        emitterChainId = parsedMessage.emitterChainId;
        emitterAddress = parsedMessage.emitterAddress;
    }

    /// @dev Resolve the local ERC-20 address referenced by a decoded Wormhole
    /// transfer. Foreign tokens map to wrapped assets; native-chain tokens are
    /// encoded directly as EVM addresses.
    function verifyTokenAddress(
        IWormholeTokenBridge.TransferWithPayload memory transfer
    ) internal view returns (address localAddress) {
        // Foreign assets are represented by the Token Bridge wrapper.
        if (transfer.tokenChain != tokenBridge.chainId()) {
            localAddress = tokenBridge.wrappedAsset(transfer.tokenChain, transfer.tokenAddress);
            if (localAddress == address(0)) revert TokenNotAttested();
        } else {
            // Native assets are encoded directly as an EVM address.
            localAddress = address(uint160(uint256(transfer.tokenAddress)));
        }
    }
}
