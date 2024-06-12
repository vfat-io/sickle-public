// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IFarmConnector } from "contracts/interfaces/IFarmConnector.sol";
import {
    CTokenInterface,
    ComptrollerInterface
} from "contracts/interfaces/external/compound-v2/CTokenInterfaces.sol";

struct ComptrollerExtraData {
    address[] cTokens;
}

contract ComptrollerConnector is IFarmConnector {
    error NotImplemented();

    function deposit(
        address, // target
        address, // token
        bytes memory // extraData
    ) external payable virtual override {
        revert NotImplemented();
    }

    function withdraw(
        address, // target
        uint256, // amount
        bytes memory // extraData
    ) external pure override {
        revert NotImplemented();
    }

    function claim(address target, bytes memory extraData) external override {
        ComptrollerExtraData memory comptrollerExtraData =
            abi.decode(extraData, (ComptrollerExtraData));
        ComptrollerInterface(target).claimComp(
            address(this), comptrollerExtraData.cTokens
        );
    }
}
