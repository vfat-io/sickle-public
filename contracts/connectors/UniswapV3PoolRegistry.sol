// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { UniswapV3Connector } from "contracts/connectors/UniswapV3Connector.sol";
import { IUniswapV3Pool } from
    "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from
    "contracts/interfaces/external/uniswap/IUniswapV3Factory.sol";

contract UniswapV3PoolRegistry is ICustomConnectorRegistry {
    IUniswapV3Factory public immutable factory;
    UniswapV3Connector public immutable connector;

    constructor(IUniswapV3Factory factory_, UniswapV3Connector connector_) {
        factory = factory_;
        connector = connector_;
    }

    function connectorOf(address target)
        external
        view
        override
        returns (address)
    {
        IUniswapV3Pool pool = IUniswapV3Pool(target);

        try pool.token0() returns (address token0) {
            try pool.token1() returns (address token1) {
                try pool.fee() returns (uint24 fee) {
                    if (factory.getPool(token0, token1, fee) == target) {
                        return address(connector);
                    }
                } catch {
                    return address(0);
                }
            } catch {
                return address(0);
            }
        } catch {
            return address(0);
        }

        return address(0);
    }
}
