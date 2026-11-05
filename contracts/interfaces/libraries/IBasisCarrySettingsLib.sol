// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    IBasisCarrySettingsRegistry
} from "contracts/interfaces/IBasisCarrySettingsRegistry.sol";
import {
    BasisCarrySettings
} from "contracts/structs/BasisCarrySettingsStructs.sol";

interface IBasisCarrySettingsLib {
    function setBasisCarrySettings(
        IBasisCarrySettingsRegistry registry,
        BasisCarrySettings calldata settings
    ) external;
}
