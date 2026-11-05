// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import { ILBPair } from "contracts/interfaces/external/lfj/ILBPair.sol";

/// @title LbTokenTransferLib
/// @notice Transfers Liquidity Book bin tokens for LFJ-compatible pools.
/// @dev Liquidity Book uses batchTransferFrom instead of safeBatchTransferFrom.
contract LbTokenTransferLib {
    /// @dev Transfers LB tokens from user to Sickle
    function transferLbTokensFromUser(
        ILBPair lbPair,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external {
        lbPair.batchTransferFrom(
            Sickle(payable(address(this))).owner(), address(this), ids, amounts
        );
    }

    /// @dev Transfers LB tokens from Sickle to user
    function transferLbTokensToUser(
        ILBPair lbPair,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external {
        lbPair.batchTransferFrom(
            address(this), Sickle(payable(address(this))).owner(), ids, amounts
        );
    }
}
