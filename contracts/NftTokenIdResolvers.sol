// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import {
    INftTokenIdResolver
} from "contracts/interfaces/INftTokenIdResolver.sol";
import { ICLGauge } from "contracts/interfaces/external/aerodrome/ICLGauge.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";

contract NftOwnerTokenIdResolver is INftTokenIdResolver {
    function tokenIdOf(
        Sickle sickle,
        NftPosition calldata position
    ) external view returns (uint256) {
        uint256 balance = position.nft.balanceOf(address(sickle));
        if (balance == 0) revert NftTokenNotFound();
        return position.nft.tokenOfOwnerByIndex(address(sickle), balance - 1);
    }
}

contract AerodromeNftTokenIdResolver is INftTokenIdResolver {
    function tokenIdOf(
        Sickle sickle,
        NftPosition calldata position
    ) external view returns (uint256) {
        ICLGauge gauge = ICLGauge(position.farm.stakingContract);
        if (gauge.nft() != address(position.nft)) {
            revert InvalidNftTokenResolver();
        }
        uint256 stakedBalance = gauge.stakedLength(address(sickle));
        if (stakedBalance == 0) revert NftTokenNotFound();
        return gauge.stakedByIndex(address(sickle), stakedBalance - 1);
    }
}
