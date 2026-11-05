// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { ThenaGaugeConnector } from
    "contracts/connectors/thena/ThenaGaugeConnector.sol";

interface IThenaVoter {
    function gaugeForPool(
        address pool
    ) external view returns (address);
}

interface IThenaGauge {
    function TOKEN() external view returns (address);
}

interface IThenaPairFactory {
    function isPair(
        address pair
    ) external view returns (bool);
}

contract ThenaGaugeRegistry is ICustomConnectorRegistry {
    IThenaVoter public immutable voter;
    IThenaPairFactory public immutable v2PairFactory;
    ThenaGaugeConnector public immutable v2GaugeConnector;

    constructor(
        IThenaVoter voter_,
        IThenaPairFactory v2PairFactory_,
        ThenaGaugeConnector v2GaugeConnector_
    ) {
        voter = voter_;
        v2PairFactory = v2PairFactory_;
        v2GaugeConnector = v2GaugeConnector_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        (bool success, bytes memory result) =
            address(target).staticcall(abi.encodeCall(IThenaGauge.TOKEN, ()));
        if (!success || result.length != 32) {
            return address(0);
        }
        address pool = abi.decode(result, (address));
        if (pool == address(0)) {
            return address(0);
        }
        address gauge = voter.gaugeForPool(pool);
        if (gauge == target && v2PairFactory.isPair(pool)) {
            return address(v2GaugeConnector);
        }
        return address(0);
    }
}
