// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    MasterchefConnector
} from "contracts/connectors/MasterchefConnector.sol";
import { Farm } from "contracts/interfaces/IFarmConnector.sol";

interface IGigaMasterchefV2 {
    function pendingReward(
        uint256 _pid,
        address _user
    ) external view returns (uint256);
}

contract GigaMasterchefV2Connector is MasterchefConnector {
    function earned(
        Farm calldata farm,
        address user,
        address[] calldata
    ) external view virtual override returns (uint256[] memory) {
        uint256[] memory rewards = new uint256[](1);
        rewards[0] = IGigaMasterchefV2(farm.stakingContract)
            .pendingReward(farm.poolIndex, user);
        return rewards;
    }
}
