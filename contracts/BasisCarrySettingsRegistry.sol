// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import { SickleFactory } from "contracts/SickleFactory.sol";
import {
    BasisCarrySettings,
    AutoFundingMode
} from "contracts/structs/BasisCarrySettingsStructs.sol";
import {
    IBasisCarrySettingsRegistry
} from "contracts/interfaces/IBasisCarrySettingsRegistry.sol";
import {
    IGmxDataStore,
    GmxStorageKeys
} from "contracts/interfaces/external/gmx/IGmxV2.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @notice Per-Sickle on-chain settings + local GMX trigger checks for the
///         basis-carry short leg.
///
/// The registry deliberately does not read LP NFTs or vaults. Cross-chain
/// portfolios pair LP legs and GMX legs off-chain; this contract only verifies
/// that an automator action is authorized for the local GMX market/collateral
/// and stays inside user-defined caps.
contract BasisCarrySettingsRegistry is IBasisCarrySettingsRegistry {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant FLOAT_PRECISION = 1e30;

    SickleFactory public immutable factory;
    IGmxDataStore public immutable gmxDataStore;
    address public immutable usdCollateralToken;

    mapping(Sickle => BasisCarrySettings) private _settings;

    constructor(
        SickleFactory factory_,
        IGmxDataStore gmxDataStore_,
        address usdCollateralToken_
    ) {
        factory = factory_;
        gmxDataStore = gmxDataStore_;
        if (usdCollateralToken_ == address(0)) {
            revert ZeroAddress();
        }
        usdCollateralToken = usdCollateralToken_;
    }

    function getSettings(
        Sickle sickle
    ) external view returns (BasisCarrySettings memory) {
        return _settings[sickle];
    }

    function setSettings(
        BasisCarrySettings calldata settings
    ) external {
        Sickle sickle = _sickleOfOwner(msg.sender);
        _setSettings(sickle, settings);
    }

    function setSettingsForSickle(
        Sickle sickle,
        BasisCarrySettings calldata settings
    ) external {
        // Only callable in Sickle delegate-call context: strategies invoke a
        // settings library via sickle.multicall, so `msg.sender` is the Sickle
        // itself. Factory lookup ensures the Sickle is a real protocol Sickle.
        if (msg.sender != address(sickle)) revert OnlySickle();
        if (factory.sickles(sickle.owner()) != address(sickle)) {
            revert SickleNotDeployed();
        }
        _setSettings(sickle, settings);
    }

    function clearSettings() external {
        Sickle sickle = _sickleOfOwner(msg.sender);
        delete _settings[sickle];
        emit SettingsCleared(sickle);
    }

    function validateDeleverageFor(
        Sickle sickle,
        address market,
        address collateralToken,
        uint256 collateralAmount
    ) external view {
        BasisCarrySettings memory s = _settings[sickle];
        if (!s.autoDeleverageEnabled) revert AutoDeleverageNotEnabled();
        _validateIdentity(s, market, collateralToken);
        if (
            s.maxDeleverageCollateralPerCall != 0
                && collateralAmount > s.maxDeleverageCollateralPerCall
        ) revert CollateralCapExceeded();

        if (s.deleverageTriggerLeverageBp != 0) {
            uint256 currentLeverageBp =
                _currentShortLeverageBp(sickle, market, collateralToken);
            if (currentLeverageBp <= s.deleverageTriggerLeverageBp) {
                revert LeverageBelowTrigger();
            }
        }
    }

    function validateRebalanceFor(
        Sickle sickle,
        address market,
        address collateralToken,
        uint256 sizeDeltaUsd
    ) external view {
        BasisCarrySettings memory s = _settings[sickle];
        if (!s.autoRebalanceEnabled) revert AutoRebalanceNotEnabled();
        _validateIdentity(s, market, collateralToken);
        if (
            s.maxRebalanceSizeDeltaUsdPerCall != 0
                && sizeDeltaUsd > s.maxRebalanceSizeDeltaUsdPerCall
        ) revert SizeDeltaCapExceeded();
    }

    function validateHarvestFor(
        Sickle sickle,
        address market,
        address token
    ) external view {
        BasisCarrySettings memory s = _settings[sickle];
        if (market != s.market) revert MarketMismatch();

        address longFundingToken = _marketLongToken(s.market);
        bool isCollateralFunding = token == s.collateralToken;
        bool isLongFunding =
            longFundingToken != s.collateralToken && token == longFundingToken;

        if (isCollateralFunding) {
            if (s.autoFundingMode != AutoFundingMode.TO_WALLET) {
                revert AutoFundingClaimNotEnabled();
            }
            _validateClaimableFundingTrigger(s, sickle, market, token);
            return;
        }

        if (isLongFunding) {
            if (s.autoFundingMode == AutoFundingMode.DISABLED) {
                revert AutoFundingClaimNotEnabled();
            }
            return;
        }

        revert FundingTokenMismatch(token, s.collateralToken, longFundingToken);
    }

    function validateCompoundFor(
        Sickle sickle,
        address market,
        address collateralToken,
        uint256 sizeDeltaUsd
    ) external view {
        BasisCarrySettings memory s = _settings[sickle];
        if (s.autoFundingMode != AutoFundingMode.COMPOUND) {
            revert AutoFundingCompoundNotEnabled();
        }
        _validateIdentity(s, market, collateralToken);
        if (
            s.maxCompoundSizeDeltaUsdPerCall != 0
                && sizeDeltaUsd > s.maxCompoundSizeDeltaUsdPerCall
        ) revert CompoundSizeDeltaCapExceeded();

        if (s.minClaimableFundingUsd != 0) {
            uint256 amt = gmxDataStore.getUint(
                GmxStorageKeys.claimableFundingAmountKey(
                    market, collateralToken, address(sickle)
                )
            );
            uint256 totalUsd = amt == 0 ? 0 : _toUsd1e30(amt, collateralToken);
            if (totalUsd < s.minClaimableFundingUsd) {
                revert ClaimableFundingBelowTrigger();
            }
        }
    }

    function validateExitFor(
        Sickle sickle,
        address market,
        address collateralToken
    ) external view {
        BasisCarrySettings memory s = _settings[sickle];
        if (!s.autoExitEnabled) revert AutoExitNotEnabled();
        _validateIdentity(s, market, collateralToken);

        int256 currentBp = _currentNetFundingRateToShortBp(s);
        if (currentBp > s.exitFundingRateBpThreshold) {
            revert FundingRateAboveExitThreshold(
                currentBp, s.exitFundingRateBpThreshold
            );
        }
    }

    function validateCancelOrderFor(
        Sickle sickle
    ) external view {
        if (!_settings[sickle].autoCancelOrderEnabled) {
            revert AutoCancelOrderNotEnabled();
        }
    }

    function currentShortPosition(
        Sickle sickle,
        address market,
        address collateralToken
    ) external view returns (uint256 sizeInUsd, uint256 collateralAmount) {
        bytes32 posKey = GmxStorageKeys.positionKey(
            address(sickle), market, collateralToken, false
        );
        sizeInUsd = gmxDataStore.getUint(GmxStorageKeys.sizeInUsdKey(posKey));
        collateralAmount =
            gmxDataStore.getUint(GmxStorageKeys.collateralAmountKey(posKey));
    }

    function _setSettings(
        Sickle sickle,
        BasisCarrySettings calldata settings
    ) private {
        // Leverage and funding triggers scale collateral balances directly
        // into 1e30 USD, so this registry intentionally supports only the
        // deployment-declared USD collateral token.
        if (settings.collateralToken != usdCollateralToken) {
            revert InvalidUsdCollateralToken(
                settings.collateralToken, usdCollateralToken
            );
        }
        _validateMarketTokens(settings);
        _settings[sickle] = settings;
        emit SettingsSet(sickle, settings);
    }

    function _validateIdentity(
        BasisCarrySettings memory s,
        address market,
        address collateralToken
    ) private pure {
        if (s.market != market) revert MarketMismatch();
        if (s.collateralToken != collateralToken) {
            revert CollateralTokenMismatch();
        }
    }

    function _validateClaimableFundingTrigger(
        BasisCarrySettings memory s,
        Sickle sickle,
        address market,
        address token
    ) private view {
        if (s.minClaimableFundingUsd == 0) return;
        uint256 amt = gmxDataStore.getUint(
            GmxStorageKeys.claimableFundingAmountKey(
                market, token, address(sickle)
            )
        );
        uint256 totalUsd = amt == 0 ? 0 : _toUsd1e30(amt, token);
        if (totalUsd < s.minClaimableFundingUsd) {
            revert ClaimableFundingBelowTrigger();
        }
    }

    function _validateMarketTokens(
        BasisCarrySettings calldata s
    ) private view {
        address marketToken =
            gmxDataStore.getAddress(GmxStorageKeys.marketTokenKey(s.market));
        address longToken = _marketLongToken(s.market);
        address shortToken = gmxDataStore.getAddress(
            GmxStorageKeys.marketShortTokenKey(s.market)
        );

        if (
            marketToken != s.market || longToken == address(0)
                || shortToken == address(0)
        ) {
            revert InvalidMarket(s.market);
        }
        if (shortToken != s.collateralToken) {
            revert InvalidMarketCollateralToken(s.collateralToken, shortToken);
        }
        if (!_matchesConfiguredLongToken(s.longToken, longToken, shortToken)) {
            revert InvalidMarketLongToken(s.longToken, longToken);
        }
    }

    function _marketLongToken(
        address market
    ) private view returns (address) {
        return
            gmxDataStore.getAddress(GmxStorageKeys.marketLongTokenKey(market));
    }

    function _matchesConfiguredLongToken(
        address configured,
        address expected,
        address collateralToken
    ) private pure returns (bool) {
        if (configured == expected) return true;
        return expected == collateralToken && configured == address(0);
    }

    function _currentShortLeverageBp(
        Sickle sickle,
        address market,
        address collateralToken
    ) internal view returns (uint256) {
        bytes32 posKey = GmxStorageKeys.positionKey(
            address(sickle), market, collateralToken, false
        );
        uint256 sizeInUsd =
            gmxDataStore.getUint(GmxStorageKeys.sizeInUsdKey(posKey));
        uint256 collateralAmount =
            gmxDataStore.getUint(GmxStorageKeys.collateralAmountKey(posKey));
        if (collateralAmount == 0) return 0;
        uint256 collateralUsd = _toUsd1e30(collateralAmount, collateralToken);
        return (sizeInUsd * BPS) / collateralUsd;
    }

    function _currentNetFundingRateToShortBp(
        BasisCarrySettings memory s
    ) internal view returns (int256) {
        // Coarse local trigger only. GMX Reader's next-rate path also applies
        // stable-funding bands and caps; automation should treat this as an
        // inexpensive guard, not a byte-for-byte Reader replacement.
        int256 saved = gmxDataStore.getInt(
            GmxStorageKeys.savedFundingFactorPerSecondKey(s.market)
        );
        if (saved == 0) return 0;

        // GMX V2 splits OI by collateral choice: a market may accept
        // longCollateral + shortCollateral as deposit options. Sum both sides.
        // Dedupe when longToken == collateralToken (synthetic markets where
        // both sides post the same stable) so we don't double-count.
        uint256 longOI = gmxDataStore.getUint(
            GmxStorageKeys.openInterestKey(s.market, s.collateralToken, true)
        );
        uint256 shortOI = gmxDataStore.getUint(
            GmxStorageKeys.openInterestKey(s.market, s.collateralToken, false)
        );
        if (s.longToken != address(0) && s.longToken != s.collateralToken) {
            longOI += gmxDataStore.getUint(
                GmxStorageKeys.openInterestKey(s.market, s.longToken, true)
            );
            shortOI += gmxDataStore.getUint(
                GmxStorageKeys.openInterestKey(s.market, s.longToken, false)
            );
        }

        bool longsPayShorts = saved > 0;
        uint256 absFactor = uint256(longsPayShorts ? saved : -saved);

        if (longsPayShorts) {
            uint256 received =
                shortOI == 0 ? absFactor : (absFactor * longOI) / shortOI;
            return int256(_annualizeFactorBp(received));
        }
        return -int256(_annualizeFactorBp(absFactor));
    }

    function _annualizeFactorBp(
        uint256 factor
    ) internal pure returns (uint256) {
        uint256 secondsPerYear = 365 * 86_400;
        return (factor * secondsPerYear * BPS) / FLOAT_PRECISION;
    }

    function _toUsd1e30(
        uint256 amount,
        address token
    ) internal view returns (uint256) {
        uint8 dec = IERC20Decimals(token).decimals();
        return amount * (10 ** (30 - dec));
    }

    function _sickleOfOwner(
        address owner
    ) private view returns (Sickle) {
        address sickle = factory.sickles(owner);
        if (sickle == address(0)) revert SickleNotDeployed();
        return Sickle(payable(sickle));
    }
}
