// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import {
    MultiCompoundParams,
    NftMultiCompoundParams
} from "contracts/structs/MultiFarmStrategyStructs.sol";

/// @notice Automation entrypoints for consolidating multiple source positions
/// (any mix of ERC20 farms and NFT positions) into a single target. Callable
/// only by a Sickle's approved address (the Automation contract).
interface IMultiAutomation {
    function compoundMultipleFor(
        Sickle sickle,
        MultiCompoundParams calldata params,
        address[] calldata sweepTokens
    ) external;

    function nftCompoundMultipleFor(
        Sickle sickle,
        NftMultiCompoundParams calldata params,
        address[] calldata sweepTokens
    ) external;
}
