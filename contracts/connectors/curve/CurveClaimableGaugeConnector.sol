// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
import { CurveGaugeConnectorBase } from "./CurveGaugeConnectorBase.sol";
import {
    ICurveLiquidityResolver
} from "contracts/interfaces/external/curve/ICurveMetaRegistry.sol";
import {
    ICurveGauge
} from "contracts/interfaces/external/curve/ICurveGauge.sol";

abstract contract CurveClaimableGaugeConnector is CurveGaugeConnectorBase {
    constructor(
        ICurveLiquidityResolver resolver_,
        address minter_
    ) CurveGaugeConnectorBase(resolver_, minter_) { }

    function _claimExtra(
        address gauge
    ) internal override {
        ICurveGauge(gauge).claim_rewards();
    }

    function _extraEarned(
        address gauge,
        address user,
        address token
    ) internal view override returns (uint256) {
        return ICurveGauge(gauge).claimable_reward(user, token);
    }
}
