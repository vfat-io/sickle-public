// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import {
    INftDepositCallback
} from "contracts/interfaces/INftDepositCallback.sol";
import {
    INftRebalanceCallback
} from "contracts/interfaces/INftRebalanceCallback.sol";

interface INftFarmVault is INftRebalanceCallback, INftDepositCallback {
    function sickle() external view returns (Sickle);
}
