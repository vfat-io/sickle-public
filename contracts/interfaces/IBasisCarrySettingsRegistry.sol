// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import {
    BasisCarrySettings
} from "contracts/structs/BasisCarrySettingsStructs.sol";

interface IBasisCarrySettingsRegistry {
    error AutoDeleverageNotEnabled();
    error AutoRebalanceNotEnabled();
    error AutoExitNotEnabled();
    error AutoCancelOrderNotEnabled();
    error AutoFundingClaimNotEnabled();
    error AutoFundingCompoundNotEnabled();
    error CollateralCapExceeded();
    error SizeDeltaCapExceeded();
    error CompoundSizeDeltaCapExceeded();
    error ZeroAddress();
    error InvalidUsdCollateralToken(address token, address expected);
    error InvalidMarket(address market);
    error InvalidMarketCollateralToken(address token, address expected);
    error InvalidMarketLongToken(address token, address expected);
    error FundingTokenMismatch(
        address token, address collateralToken, address longToken
    );
    error MarketMismatch();
    error CollateralTokenMismatch();
    error OnlySickle();
    error SickleNotDeployed();
    error LeverageBelowTrigger();
    error ClaimableFundingBelowTrigger();
    error FundingRateAboveExitThreshold(int256 currentBp, int256 thresholdBp);

    event SettingsSet(Sickle indexed sickle, BasisCarrySettings settings);
    event SettingsCleared(Sickle indexed sickle);

    function getSettings(
        Sickle sickle
    ) external view returns (BasisCarrySettings memory);

    function setSettings(
        BasisCarrySettings calldata settings
    ) external;

    /// @notice Strategy-authorized settings write used while opening the GMX
    ///         leg. Must be invoked in Sickle delegate-call context: the
    ///         registry trusts `msg.sender == address(sickle)` and verifies
    ///         the Sickle was deployed by the factory.
    function setSettingsForSickle(
        Sickle sickle,
        BasisCarrySettings calldata settings
    ) external;

    function clearSettings() external;

    function validateDeleverageFor(
        Sickle sickle,
        address market,
        address collateralToken,
        uint256 collateralAmount
    ) external view;

    function validateRebalanceFor(
        Sickle sickle,
        address market,
        address collateralToken,
        uint256 sizeDeltaUsd
    ) external view;

    function validateHarvestFor(
        Sickle sickle,
        address market,
        address token
    ) external view;

    function validateCompoundFor(
        Sickle sickle,
        address market,
        address collateralToken,
        uint256 sizeDeltaUsd
    ) external view;

    function validateExitFor(
        Sickle sickle,
        address market,
        address collateralToken
    ) external view;

    function validateCancelOrderFor(
        Sickle sickle
    ) external view;

    function currentShortPosition(
        Sickle sickle,
        address market,
        address collateralToken
    ) external view returns (uint256 sizeInUsd, uint256 collateralAmount);
}
