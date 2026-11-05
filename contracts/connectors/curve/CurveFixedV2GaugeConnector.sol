// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
import {
    CurveGaugeConnectorBase,
    CurveGaugeRewards,
    ICurveLegacyGauge
} from "./CurveGaugeConnectorBase.sol";
import {
    ICurveLiquidityResolver
} from "contracts/interfaces/external/curve/ICurveMetaRegistry.sol";
import {
    ICurveGauge
} from "contracts/interfaces/external/curve/ICurveGauge.sol";

contract CurveFixedV2GaugeConnector is CurveGaugeConnectorBase {
    constructor(
        ICurveLiquidityResolver resolver_,
        address minter_
    ) CurveGaugeConnectorBase(resolver_, minter_) { }

    function rewardType() public pure override returns (CurveGaugeRewards) {
        return CurveGaugeRewards.FixedV2;
    }

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
        uint256 integral = ICurveLegacyGauge(gauge).reward_integral(token);
        uint256 integralFor =
            ICurveLegacyGauge(gauge).reward_integral_for(token, user);
        return integral > integralFor
            ? ICurveGauge(gauge).balanceOf(user) * (integral - integralFor)
                / 1e18
            : 0;
    }
}
