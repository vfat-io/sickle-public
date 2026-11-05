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

contract CurveSingleRewardGaugeConnector is CurveGaugeConnectorBase {
    constructor(
        ICurveLiquidityResolver resolver_,
        address minter_
    ) CurveGaugeConnectorBase(resolver_, minter_) { }

    function rewardType() public pure override returns (CurveGaugeRewards) {
        return CurveGaugeRewards.Single;
    }

    function isKilled(
        address gauge
    ) public view override returns (bool) {
        return gauge.codehash
            == 0xc928d7ec49b9505da6bc9992cd78e3d835d7b6d032d45d5ff1d4baab6b7f2ca6
            ? false
            : ICurveGauge(gauge).is_killed();
    }

    function _claimExtra(
        address gauge
    ) internal override {
        if (_singleEarned(gauge, address(this)) != 0) {
            ICurveGauge(gauge).claim_rewards();
        }
    }

    function _extraEarned(
        address gauge,
        address user,
        address token
    ) internal view override returns (uint256) {
        return token == ICurveLegacyGauge(gauge).rewarded_token()
            ? _singleEarned(gauge, user)
            : 0;
    }

    function _singleEarned(
        address gauge,
        address user
    ) private view returns (uint256) {
        uint256 accrued = ICurveLegacyGauge(gauge).claimable_reward(user);
        uint256 claimed = ICurveLegacyGauge(gauge).claimed_rewards_for(user);
        return accrued > claimed ? accrued - claimed : 0;
    }
}
