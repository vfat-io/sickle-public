// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ILBPair } from "./ILBPair.sol";

interface ILBFactory {
    struct LBPairInformation {
        uint16 binStep;
        ILBPair LBPair;
        bool createdByOwner;
        bool ignoredForRouting;
    }

    function getLBPairInformation(
        IERC20 tokenX,
        IERC20 tokenY,
        uint256 binStep
    ) external view returns (LBPairInformation memory);

    function getPreset(
        uint256 binStep
    )
        external
        view
        returns (
            uint256 baseFactor,
            uint256 filterPeriod,
            uint256 decayPeriod,
            uint256 reductionFactor,
            uint256 variableFeeControl,
            uint256 protocolShare,
            uint256 maxVolatilityAccumulator,
            bool isOpen
        );

    function getAllBinSteps() external view returns (uint256[] memory);

    function getAllLBPairs(
        IERC20 tokenX,
        IERC20 tokenY
    ) external view returns (LBPairInformation[] memory);

    function getLBPairAtIndex(
        uint256 index
    ) external view returns (ILBPair);

    function getNumberOfLBPairs() external view returns (uint256);

    function createLBPair(
        IERC20 tokenX,
        IERC20 tokenY,
        uint24 activeId,
        uint16 binStep
    ) external returns (ILBPair pair);
}
