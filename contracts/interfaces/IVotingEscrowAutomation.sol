// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import { Farm } from "contracts/structs/FarmStrategyStructs.sol";

/// @title IVotingEscrowAutomation
/// @notice Keeper actions for a Sickle's voting-escrow NFTs, dispatched
/// through `Automation.executeFor`. Each takes the Sickle first (executeFor
/// binds it to the calldata's leading argument). `voteFor` is bound to the
/// VE_VOTE permission bit, `claimRemoteFor` to FARM_HARVEST.
/// @dev `messageFee` pays messages to other chains from the Sickle's
/// MessageFeeAccount balance; zero for actions on the escrow's own chain
/// only.
interface IVotingEscrowAutomation {
    /// @notice Set the gauge votes of NFTs held by `sickle`, as the owner's
    /// `vote` would.
    function voteFor(
        Sickle sickle,
        Farm calldata farm,
        bytes calldata extraData,
        uint256 messageFee
    ) external;

    /// @notice Claim rewards of NFTs held by `sickle` on other chains, paid
    /// to the owner's recipients there. Requires reward automation in the
    /// farm's position settings.
    function claimRemoteFor(
        Sickle sickle,
        Farm calldata farm,
        bytes calldata extraData,
        uint256 messageFee
    ) external;
}
