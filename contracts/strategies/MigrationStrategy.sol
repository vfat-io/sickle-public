// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../Sickle.sol";
import "../SickleFactory.sol";
import "../ConnectorRegistry.sol";
import "../interfaces/IFarmConnector.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

interface IOldSickle {
    function multicall(
        address[] calldata targets,
        bytes[] calldata data,
        bool[] calldata isDelegateCall,
        uint256[] calldata values
    ) external payable;
}

contract MigrationStrategy {
    SickleFactory public immutable oldFactory;
    SickleFactory public immutable newFactory;
    ConnectorRegistry public immutable oldConnectorRegistry;
    ConnectorRegistry public immutable connectorRegistry;

    error NotRegisteredSickle();
    error NotOwner(address sender);

    constructor(
        SickleFactory oldFactory_,
        SickleFactory newFactory_,
        ConnectorRegistry oldConnectorRegistry_,
        ConnectorRegistry connectorRegistry_
    ) {
        oldFactory = oldFactory_;
        newFactory = newFactory_;
        connectorRegistry = connectorRegistry_;
        oldConnectorRegistry = oldConnectorRegistry_;
    }

    function _transfer(address token, address to) external {
        if (oldFactory.admins(address(this)) == address(0)) {
            revert NotRegisteredSickle();
        }
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount > 0) {
            SafeTransferLib.safeTransfer(token, to, amount);
        }
    }

    struct MigrationInfo {
        address stakingContractAddress;
        address lpToken;
        address rewardToken;
        bytes withdrawExtraData;
        bytes claimExtraData;
        bytes depositExtraData;
        uint256 amount;
    }

    function migrate(
        address oldSickleAddress,
        MigrationInfo calldata migrationInfo,
        address approved,
        bytes32 referralCode
    ) public {
        IOldSickle oldSickle = IOldSickle(payable(oldSickleAddress));
        if (oldFactory.admins(oldSickleAddress) != msg.sender) {
            revert NotOwner(msg.sender);
        }

        Sickle newSickle = Sickle(
            payable(newFactory.getOrDeploy(msg.sender, approved, referralCode))
        );

        address[] memory targets = new address[](4);
        bytes[] memory data = new bytes[](4);
        bool[] memory isDelegateCall = new bool[](4);
        uint256[] memory values = new uint256[](4);

        address oldFarmConnector = oldConnectorRegistry.connectorOf(
            migrationInfo.stakingContractAddress
        );

        targets[0] = oldFarmConnector;
        data[0] = abi.encodeCall(
            IFarmConnector.withdraw,
            (
                migrationInfo.stakingContractAddress,
                migrationInfo.amount,
                migrationInfo.withdrawExtraData
            )
        );
        isDelegateCall[0] = true;

        targets[1] = address(this);
        data[1] = abi.encodeCall(
            this._transfer, (migrationInfo.lpToken, address(newSickle))
        );
        isDelegateCall[1] = true;

        targets[2] = oldFarmConnector;
        data[2] = abi.encodeCall(
            IFarmConnector.claim,
            (migrationInfo.stakingContractAddress, migrationInfo.claimExtraData)
        );
        isDelegateCall[2] = true;

        targets[3] = address(this);
        data[3] = abi.encodeCall(
            this._transfer, (migrationInfo.rewardToken, msg.sender)
        );
        isDelegateCall[3] = true;

        oldSickle.multicall(targets, data, isDelegateCall, values);

        address farmConnector =
            connectorRegistry.connectorOf(migrationInfo.stakingContractAddress);

        address[] memory targets2 = new address[](1);
        bytes[] memory data2 = new bytes[](1);

        targets2[0] = farmConnector;
        data2[0] = abi.encodeCall(
            IFarmConnector.deposit,
            (
                migrationInfo.stakingContractAddress,
                migrationInfo.lpToken,
                migrationInfo.depositExtraData
            )
        );

        newSickle.multicall(targets2, data2);
    }

    function migrateMultiple(
        address oldSickleAddress,
        MigrationInfo[] calldata migrationInfos,
        address approved,
        bytes32 referralCode
    ) public {
        for (uint256 i = 0; i < migrationInfos.length;) {
            migrate(oldSickleAddress, migrationInfos[i], approved, referralCode);

            unchecked {
                i++;
            }
        }
    }
}
