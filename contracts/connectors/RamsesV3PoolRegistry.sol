// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../ConnectorRegistry.sol";
import "./RamsesV3Connector.sol";

import "../interfaces/external/ramses/IRamsesV2Pool.sol";
import "../interfaces/external/uniswap/IUniswapV3Factory.sol";

contract RamsesV3PoolRegistry is ICustomConnectorRegistry {
    IUniswapV3Factory public immutable factory;
    RamsesV3Connector public immutable connector;

    constructor(IUniswapV3Factory factory_, RamsesV3Connector connector_) {
        factory = factory_;
        connector = connector_;
    }

    function connectorOf(address target)
        external
        view
        override
        returns (address)
    {
        IRamsesV2Pool pool = IRamsesV2Pool(target);

        (bool success0, bytes memory returnData0) =
            address(pool).staticcall(abi.encodeWithSignature("token0()"));

        if (success0) {
            address token0 = abi.decode(returnData0, (address));

            (bool success1, bytes memory returnData1) =
                address(pool).staticcall(abi.encodeWithSignature("token1()"));

            if (success1) {
                address token1 = abi.decode(returnData1, (address));

                (bool successFee, bytes memory returnDataFee) =
                    address(pool).staticcall(abi.encodeWithSignature("fee()"));

                if (successFee) {
                    uint24 fee = abi.decode(returnDataFee, (uint24));

                    if (factory.getPool(token0, token1, fee) == target) {
                        return address(connector);
                    }
                }
            }
        }

        return address(0);
    }
}
