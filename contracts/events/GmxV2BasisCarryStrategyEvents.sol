// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";

abstract contract GmxV2BasisCarryStrategyEvents {
    event ShortOpened(
        Sickle indexed sickle,
        address indexed market,
        address indexed collateralToken
    );

    event ShortClosed(
        Sickle indexed sickle,
        address indexed market,
        address indexed collateralToken
    );

    event FundingHarvested(
        Sickle indexed sickle,
        address indexed market,
        address indexed collateralToken
    );

    event FundingCompounded(
        Sickle indexed sickle,
        address indexed market,
        address indexed collateralToken
    );

    event SettingsUpdated(
        Sickle indexed sickle,
        address indexed market,
        address indexed collateralToken
    );
}
