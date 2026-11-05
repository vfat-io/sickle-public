// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { CurveGaugeCode } from "./CurveGaugeCode.sol";
import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import {
    ICurveLiquidityResolver
} from "contracts/interfaces/external/curve/ICurveMetaRegistry.sol";
import {
    CurveGaugeConnectorBase,
    CurveGaugeRewards,
    ICurveLegacyGauge
} from "./CurveGaugeConnectorBase.sol";
import { CurveGaugeIdentity } from "./CurveGaugeIdentity.sol";
import {
    ICurveGauge
} from "contracts/interfaces/external/curve/ICurveGauge.sol";
import {
    ICurveMinter
} from "contracts/interfaces/external/curve/ICurveMinter.sol";

contract CurveLegacyGaugeRegistry is ICustomConnectorRegistry {
    error InvalidConnector();
    error UnsupportedGauge(address gauge);
    ICurveLiquidityResolver public immutable resolver;
    address public immutable minter;
    address public immutable gaugeController;
    mapping(CurveGaugeRewards => address) public gaugeConnectors;
    bytes32 private constant PLAIN_V1 =
        0x11130eae2535b52589528aebc0e8507c7d49c289a45bb2ae88555d565b194153;

    constructor(
        ICurveLiquidityResolver resolver_,
        address minter_,
        address[5] memory gauges
    ) {
        resolver = resolver_;
        minter = minter_;
        gaugeController = ICurveMinter(minter_).controller();
        for (uint256 i; i < gauges.length; i++) {
            CurveGaugeConnectorBase connector =
                CurveGaugeConnectorBase(gauges[i]);
            CurveGaugeRewards kind = CurveGaugeRewards(i);
            if (
                address(connector.resolver()) != address(resolver_)
                    || connector.minter() != minter_
                    || connector.rewardType() != kind
            ) revert InvalidConnector();
            gaugeConnectors[kind] = gauges[i];
        }
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        try this.gaugeConnectorOf(target) returns (address connector) {
            return connector;
        } catch {
            return address(0);
        }
    }

    function gaugeConnectorOf(
        address gauge
    ) external view returns (address) {
        (address lp,,) =
            CurveGaugeIdentity.resolve(resolver, gaugeController, gauge);
        if (resolver.isFactoryGauge(gauge, lp)) revert UnsupportedGauge(gauge);
        return gaugeConnectors[_rewardFamily(gauge)];
    }

    function _rewardFamily(
        address gauge
    ) private view returns (CurveGaugeRewards) {
        (bool modern,) =
            _read(gauge, abi.encodeCall(ICurveGauge.reward_count, ()));
        if (modern) return CurveGaugeRewards.Modern;
        // Canonical old gauges store these identities; newer gauges use
        // constants and omit the getters. Failed modern reads cannot become
        // empty rewards.
        if (
            ICurveLegacyGauge(gauge).minter() != minter
                || ICurveLegacyGauge(gauge).controller() != gaugeController
        ) revert UnsupportedGauge(gauge);
        (bool multi,) =
            _read(gauge, abi.encodeCall(ICurveGauge.reward_tokens, (0)));
        if (multi) {
            (bool v3,) = _read(
                gauge,
                abi.encodeCall(
                    ICurveGauge.claimed_reward, (address(0), address(0))
                )
            );
            return v3 ? CurveGaugeRewards.FixedV3 : CurveGaugeRewards.FixedV2;
        }
        (bool single,) =
            _read(gauge, abi.encodeCall(ICurveLegacyGauge.rewarded_token, ()));
        if (single) return CurveGaugeRewards.Single;
        if (
            gauge.codehash == CurveGaugeCode.PLAIN_V0
                || gauge.codehash == PLAIN_V1
        ) {
            return CurveGaugeRewards.None;
        }
        revert UnsupportedGauge(gauge);
    }

    function _read(
        address target,
        bytes memory data
    ) private view returns (bool, uint256) {
        (bool success, bytes memory result) = target.staticcall(data);
        return success && result.length == 32
            ? (true, abi.decode(result, (uint256)))
            : (false, uint256(0));
    }
}
