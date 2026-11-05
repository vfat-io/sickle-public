// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    StrategyModule,
    SickleFactory,
    Sickle,
    ConnectorRegistry
} from "contracts/modules/StrategyModule.sol";
import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";

/// @title KatanaPreStakingStrategy
/// @notice Strategy for managing KAT pre-staking on Katana Network.
/// KAT tokens are already in the Sickle (locked pre-TGE, no transfers
/// possible), so deposit only sets an approval to the StakingRouter and
/// withdraw only revokes it. No token transfers are performed.
contract KatanaPreStakingStrategy is StrategyModule {
    event PreStaked(
        Sickle indexed sickle,
        address indexed stakingContract,
        uint256 indexed poolIndex
    );

    event PreStakeRevoked(
        Sickle indexed sickle,
        address indexed stakingContract,
        uint256 indexed poolIndex
    );

    constructor(
        SickleFactory factory,
        ConnectorRegistry connectorRegistry_
    ) StrategyModule(factory, connectorRegistry_) { }

    /// @notice Pre-stake KAT tokens that are already in the Sickle by
    /// approving the StakingRouter.
    /// @param farm The farm (StakingRouter address + poolIndex).
    /// @param token The token to approve (KAT).
    /// @param extraData Extra data to pass to the connector.
    function deposit(
        Farm calldata farm,
        address token,
        bytes calldata extraData
    ) external {
        Sickle sickle = getSickle(msg.sender);

        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = connectorRegistry.connectorOf(farm.stakingContract);
        data[0] = abi.encodeCall(
            IFarmConnector.deposit, (farm, token, extraData)
        );

        sickle.multicall(targets, data);

        emit PreStaked(sickle, farm.stakingContract, farm.poolIndex);
    }

    /// @notice Revoke the pre-stake by removing the StakingRouter approval.
    /// KAT remains in the Sickle.
    /// @param farm The farm (StakingRouter address + poolIndex).
    /// @param extraData Extra data to pass to the connector.
    function withdraw(
        Farm calldata farm,
        bytes calldata extraData
    ) external {
        Sickle sickle = getSickle(msg.sender);

        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = connectorRegistry.connectorOf(farm.stakingContract);
        data[0] = abi.encodeCall(
            IFarmConnector.withdraw, (farm, 0, extraData)
        );

        sickle.multicall(targets, data);

        emit PreStakeRevoked(sickle, farm.stakingContract, farm.poolIndex);
    }
}
