// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Sickle } from "contracts/Sickle.sol";
import { DelegateModule } from "contracts/modules/DelegateModule.sol";
import { IFeesLib } from "contracts/interfaces/libraries/IFeesLib.sol";
import {
    GmxV2Connector
} from "contracts/connectors/gmx/GmxV2Connector.sol";

/// @title Basis-carry funding-fee + flush helpers
/// @notice Used by GmxV2BasisCarryStrategy.harvest{,For} and
///         compound{,For} to charge the configured fee on the *actual
///         claimed delta* and flush the post-fee remainder to the user (for
///         harvest) or feed it into a follow-up openShort (for compound),
///         leaving any pre-existing collateral-token buffer in the Sickle
///         untouched.
///
///         The Sickle is allowed to hold a USDC buffer between operations
///         (e.g. pre-funded for `deleverageFor`). The previous funding
///         flow charged fees against the full Sickle balance and then
///         swept it to the owner, which (a) over-charged the fee on the
///         buffer and (b) underflowed inside `_compoundFunding` when the
///         pre-existing buffer exceeded the just-claimed amount. Reading
///         the delta on-chain inside this lib avoids both, regardless of
///         how much funding the GMX claim actually delivers.
///
///         Designed to be invoked via Sickle delegatecall: `address(this)`
///         is the Sickle, the FeesLib + GmxV2Connector calls are nested
///         delegatecalls, and the SafeTransferLib pulls/sends from the
///         Sickle.
contract BasisCarryFundingLib is DelegateModule {
    error CompoundClaimEmpty();

    /// @dev Harvest flow: charge fee on the freshly-claimed delta and send
    ///      the remainder to `recipient`. Buffer that was already in the
    ///      Sickle at `balanceBefore` stays put. No-op if delta is zero so
    ///      the bot's call doesn't revert on an empty claim.
    function chargeAndFlush(
        IFeesLib feesLib,
        address strategy,
        bytes4 feeSel,
        address token,
        uint256 balanceBefore,
        address recipient
    ) external {
        uint256 current = IERC20(token).balanceOf(address(this));
        if (current <= balanceBefore) return;
        uint256 delta = current - balanceBefore;

        bytes memory result = _delegateTo(
            address(feesLib),
            abi.encodeCall(
                IFeesLib.chargeFee, (strategy, feeSel, token, delta)
            )
        );
        uint256 remainder = abi.decode(result, (uint256));
        if (remainder > 0) {
            SafeTransferLib.safeTransfer(token, recipient, remainder);
        }
    }

    /// @dev Compound flow: charge fee on the freshly-claimed delta and post
    ///      the post-fee remainder back to GMX as additional short collateral
    ///      via `connector.openShort`. `baseParams.collateralAmount` is
    ///      ignored; the lib overrides it with the measured remainder.
    ///      msg.value flows through (delegatecall preserves it) and is
    ///      consumed by the inner `openShort` for the GMX keeper fee.
    ///      Reverts `CompoundClaimEmpty` when delta is zero — same contract
    ///      as the previous strategy-level guard.
    function chargeAndOpenShort(
        IFeesLib feesLib,
        GmxV2Connector connector,
        address strategy,
        bytes4 feeSel,
        uint256 balanceBefore,
        GmxV2Connector.OpenShortParams memory baseParams
    ) external payable {
        uint256 current =
            IERC20(baseParams.collateralToken).balanceOf(address(this));
        if (current <= balanceBefore) revert CompoundClaimEmpty();
        uint256 delta = current - balanceBefore;

        bytes memory result = _delegateTo(
            address(feesLib),
            abi.encodeCall(
                IFeesLib.chargeFee,
                (strategy, feeSel, baseParams.collateralToken, delta)
            )
        );
        uint256 postFee = abi.decode(result, (uint256));
        if (postFee == 0) return;

        GmxV2Connector.OpenShortParams memory params = baseParams;
        params.collateralAmount = postFee;

        _delegateTo(
            address(connector), abi.encodeCall(connector.openShort, (params))
        );
    }
}
