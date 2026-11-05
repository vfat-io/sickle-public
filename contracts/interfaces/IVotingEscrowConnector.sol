// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Farm } from "contracts/structs/FarmStrategyStructs.sol";

/// @notice Voting and remote-claim surface of a farm connector for a
/// voting-escrow NFT. The farm is the escrow (`stakingContract`), its NFTs
/// held by the Sickle. Rewards on the escrow's own chain are claimed through
/// `IFarmConnector.claim`.
/// @dev Both calls may carry message fees for other chains as `msg.value`;
/// whatever is not spent or is refunded goes back to the Sickle's
/// MessageFeeAccount balance.
interface IVotingEscrowConnector {
    /// @notice Set the gauge votes of Sickle-owned escrow NFTs. The NFTs and
    /// their allocations are protocol-specific and encoded in `extraData`.
    function vote(
        Farm calldata farm,
        bytes calldata extraData
    ) external payable;

    /// @notice Claim rewards of Sickle-owned escrow NFTs on other chains,
    /// paid there to the owner's recipient for each chain.
    function claimRemote(
        Farm calldata farm,
        bytes calldata extraData
    ) external payable;
}
