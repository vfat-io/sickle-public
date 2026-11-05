// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Where rewards claimed on another chain are paid.
struct RemoteRecipient {
    uint256 chainId;
    address recipient;
}

/// @notice Owner options for a voting-escrow farm, ABI-encoded in the farm's
/// `PositionSettings.extraData` and written with the deposit. Empty
/// extraData means the defaults: no keeper actions on other chains, no fee
/// reserve, and remote rewards paid to the owner when the owner is an
/// externally owned account.
/// @param maxMessageFee Most native the keeper may spend from the Sickle's
/// fee balance on one action's messages to other chains. Zero keeps the
/// keeper on the escrow's own chain.
/// @param feeReserveTarget Native amount the Sickle's fee balance is topped
/// up to from claimed native rewards. Zero disables the top-up.
/// @param remoteRecipients Per-chain recipients for remote rewards, required
/// on any chain where the owner is a contract.
struct VotingEscrowOptions {
    uint256 maxMessageFee;
    uint256 feeReserveTarget;
    RemoteRecipient[] remoteRecipients;
}
