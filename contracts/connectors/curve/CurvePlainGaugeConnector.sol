// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
import { CurveGaugeCode } from "./CurveGaugeCode.sol";
import {
    CurveGaugeConnectorBase,
    CurveGaugeRewards
} from "./CurveGaugeConnectorBase.sol";
import {
    ICurveLiquidityResolver
} from "contracts/interfaces/external/curve/ICurveMetaRegistry.sol";
import {
    ICurveGauge
} from "contracts/interfaces/external/curve/ICurveGauge.sol";

contract CurvePlainGaugeConnector is CurveGaugeConnectorBase {
    constructor(
        ICurveLiquidityResolver resolver_,
        address minter_
    ) CurveGaugeConnectorBase(resolver_, minter_) { }

    function rewardType() public pure override returns (CurveGaugeRewards) {
        return CurveGaugeRewards.None;
    }

    function isKilled(
        address gauge
    ) public view override returns (bool) {
        return gauge.codehash == CurveGaugeCode.PLAIN_V0
            ? false
            : ICurveGauge(gauge).is_killed();
    }
    function _claimExtra(
        address
    ) internal pure override { }

    function _extraEarned(
        address,
        address,
        address
    ) internal pure override returns (uint256) {
        return 0;
    }
}
