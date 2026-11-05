// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import {
    IBasisCarrySettingsRegistry
} from "contracts/interfaces/IBasisCarrySettingsRegistry.sol";
import {
    IBasisCarrySettingsLib
} from "contracts/interfaces/libraries/IBasisCarrySettingsLib.sol";
import {
    BasisCarrySettings
} from "contracts/structs/BasisCarrySettingsStructs.sol";

contract BasisCarrySettingsLib is IBasisCarrySettingsLib {
    function setBasisCarrySettings(
        IBasisCarrySettingsRegistry registry,
        BasisCarrySettings calldata settings
    ) external {
        registry.setSettingsForSickle(
            Sickle(payable(address(this))), settings
        );
    }
}
