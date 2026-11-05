// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";

interface INftRebalanceCallback {
    /// @notice Called by Automation BEFORE the rebalance multicall, while the
    /// old position is still intact, so the callback can snapshot its value.
    function beforeRebalance(
        Sickle sickle,
        NftPosition calldata oldPosition
    ) external;

    function onRebalance(
        Sickle sickle,
        NftPosition calldata oldPosition
    ) external;
}
