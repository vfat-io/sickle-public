// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { ILBFactory } from "contracts/interfaces/external/lfj/ILBFactory.sol";
import { ILBPair } from "contracts/interfaces/external/lfj/ILBPair.sol";

/// @notice Resolves LFJ-compatible Liquidity Book pools to a router-specific
/// connector. A pool is accepted only if its configured factory returns that
/// exact pool for the token pair and bin step.
contract BinConnectorRegistry is ICustomConnectorRegistry {
    error ArrayLengthMismatch();

    ILBFactory[] public factories;
    address[] public connectors;

    constructor(
        ILBFactory[] memory factories_,
        address[] memory connectors_
    ) {
        if (factories_.length != connectors_.length) {
            revert ArrayLengthMismatch();
        }
        for (uint256 i; i < factories_.length; ++i) {
            factories.push(factories_[i]);
            connectors.push(connectors_[i]);
        }
    }

    function connectorOf(
        address target
    ) external view returns (address) {
        ILBPair pair = ILBPair(target);
        address pairFactory = pair.getFactory();
        IERC20 tokenX = pair.getTokenX();
        IERC20 tokenY = pair.getTokenY();
        uint16 binStep = pair.getBinStep();

        for (uint256 i; i < factories.length; ++i) {
            if (pairFactory != address(factories[i])) continue;
            ILBFactory.LBPairInformation memory info =
                factories[i].getLBPairInformation(tokenX, tokenY, binStep);
            if (address(info.LBPair) == target) {
                return connectors[i];
            }
        }
        return address(0);
    }
}
