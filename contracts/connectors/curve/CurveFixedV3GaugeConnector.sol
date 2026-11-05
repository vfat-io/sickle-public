// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
import { CurveGaugeRewards } from "./CurveGaugeConnectorBase.sol";
import {
    ICurveLiquidityResolver
} from "contracts/interfaces/external/curve/ICurveMetaRegistry.sol";

import {
    CurveClaimableGaugeConnector
} from "./CurveClaimableGaugeConnector.sol";

contract CurveFixedV3GaugeConnector is CurveClaimableGaugeConnector {
    constructor(
        ICurveLiquidityResolver resolver_,
        address minter_
    ) CurveClaimableGaugeConnector(resolver_, minter_) { }

    function rewardType() public pure override returns (CurveGaugeRewards) {
        return CurveGaugeRewards.FixedV3;
    }
}
