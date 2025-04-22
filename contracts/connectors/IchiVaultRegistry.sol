// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ICustomConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { IchiConnector } from "contracts/connectors/IchiConnector.sol";
import { IICHIVault } from "contracts/interfaces/external/swapx/IIchiVault.sol";

interface IICHIVaultFactory {
    function genKey(
        address deployer,
        address token0,
        address token1,
        bool allowToken0,
        bool allowToken1
    ) external pure returns (bytes32 key);

    function getICHIVault(
        bytes32 vaultKey
    ) external view returns (address);
}

contract IchiVaultRegistry is ICustomConnectorRegistry {
    IchiConnector public immutable ichiConnector;
    IICHIVaultFactory public immutable ichiVaultFactory;

    constructor(IchiConnector ichiConnector_, IICHIVaultFactory vaultFactory_) {
        ichiConnector = ichiConnector_;
        ichiVaultFactory = vaultFactory_;
    }

    function connectorOf(
        address target
    ) external view override returns (address) {
        bytes memory data =
            abi.encodeWithSelector(IICHIVault.ichiVaultFactory.selector);
        (bool success, bytes memory returnData) = target.staticcall(data);
        if (success && returnData.length == 32) {
            address result = abi.decode(returnData, (address));
            if (result == address(ichiVaultFactory)) {
                bytes32 key = ichiVaultFactory.genKey(
                    IICHIVault(target).owner(),
                    IICHIVault(target).token0(),
                    IICHIVault(target).token1(),
                    IICHIVault(target).allowToken0(),
                    IICHIVault(target).allowToken1()
                );
                address ichiVault = ichiVaultFactory.getICHIVault(key);
                if (ichiVault == target) {
                    return address(ichiConnector);
                } else {
                    return address(0);
                }
            } else {
                return address(0);
            }
        } else {
            return address(0);
        }
    }
}
