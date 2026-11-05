// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import {
    NftIncrease,
    NftPosition
} from "contracts/structs/NftFarmStrategyStructs.sol";

interface INftDepositCallback {
    function beforeDeposit(
        Sickle sickle,
        NftPosition calldata position,
        NftIncrease calldata increase
    ) external;
}
