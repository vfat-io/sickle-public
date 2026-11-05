// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Sickle } from "contracts/Sickle.sol";
import { ILBPair } from "contracts/interfaces/external/lfj/ILBPair.sol";

contract BinFarmStrategyEvents {
    event SickleDepositedBin(
        Sickle indexed sickle,
        ILBPair indexed lbPair,
        address indexed stakingContract,
        uint256 poolIndex,
        uint256[] binIds,
        uint256[] amounts
    );

    event SickleWithdrewBin(
        Sickle indexed sickle,
        ILBPair indexed lbPair,
        address indexed stakingContract,
        uint256 poolIndex,
        uint256[] binIds,
        uint256[] amounts
    );

    event SickleHarvestedBin(
        Sickle indexed sickle,
        ILBPair indexed lbPair,
        address indexed stakingContract,
        uint256 poolIndex
    );

    event SickleCompoundedBin(
        Sickle indexed sickle,
        ILBPair indexed lbPair,
        address indexed stakingContract,
        uint256 poolIndex,
        uint256[] binIds,
        uint256[] amounts
    );

    event SickleExitedBin(
        Sickle indexed sickle,
        ILBPair indexed lbPair,
        address indexed stakingContract,
        uint256 poolIndex,
        uint256[] binIds,
        uint256[] amounts
    );

    event SickleIncreasedBin(
        Sickle indexed sickle,
        ILBPair indexed lbPair,
        address indexed stakingContract,
        uint256 poolIndex,
        uint256[] binIds,
        uint256[] amounts
    );

    event SickleRebalancedBin(
        Sickle indexed sickle,
        ILBPair indexed lbPair,
        address indexed stakingContract,
        uint256 poolIndex,
        uint256[] oldBinIds,
        uint256[] oldAmounts,
        uint256[] newBinIds,
        uint256[] newAmounts
    );

    event SickleMovedBin(
        Sickle indexed sickle,
        ILBPair indexed lbPairFrom,
        address indexed stakingContractFrom,
        uint256 poolIndexFrom,
        ILBPair lbPairTo,
        address stakingContractTo,
        uint256 poolIndexTo,
        uint256[] oldBinIds,
        uint256[] oldAmounts,
        uint256[] newBinIds,
        uint256[] newAmounts
    );
}
