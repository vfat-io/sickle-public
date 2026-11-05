// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
import {
    ICurveLiquidityResolver,
    CurveLiquidityPool
} from "contracts/interfaces/external/curve/ICurveMetaRegistry.sol";
import {
    ICurveGauge
} from "contracts/interfaces/external/curve/ICurveGauge.sol";
import { ICurveGaugeController } from "./CurveCrvRewards.sol";

library CurveGaugeIdentity {
    error UnsupportedGauge(address gauge);

    function resolve(
        ICurveLiquidityResolver resolver,
        address controller,
        address gauge
    ) internal view returns (address lp, bool current, bool emissions) {
        lp = readAddress(gauge, abi.encodeCall(ICurveGauge.lp_token, ()));
        if (lp == address(0)) revert UnsupportedGauge(gauge);
        try resolver.poolInfo(lp) returns (CurveLiquidityPool memory pool) {
            if (pool.lpToken == lp) {
                try resolver.metaRegistry().get_gauge(pool.pool) returns (
                    address registered
                ) {
                    current = registered == gauge;
                } catch { }
            }
        } catch { }
        emissions = hasEmissions(controller, gauge);
        if (!current && !emissions && !resolver.isFactoryGauge(gauge, lp)) {
            revert UnsupportedGauge(gauge);
        }
    }

    function hasEmissions(
        address controller,
        address gauge
    ) internal view returns (bool) {
        try ICurveGaugeController(controller).gauge_types(gauge) returns (
            int128 kind
        ) {
            return kind >= 0;
        } catch (bytes memory reason) {
            if (reason.length != 0) revert UnsupportedGauge(gauge);
            return false;
        }
    }

    function readAddress(
        address target,
        bytes memory data
    ) internal view returns (address) {
        (bool ok, bytes memory result) = target.staticcall{ gas: 50_000 }(data);
        if (!ok || result.length != 32) return address(0);
        uint256 value = abi.decode(result, (uint256));
        return value <= type(uint160).max ? address(uint160(value)) : address(0);
    }
}
