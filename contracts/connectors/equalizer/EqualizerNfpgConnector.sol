// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    INftFarmConnector,
    NftPosition
} from "contracts/interfaces/INftFarmConnector.sol";
import { INFPG } from "contracts/interfaces/external/equalizer/INFPG.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract EqualizerNfpgConnector is INftFarmConnector {
    function depositExistingNft(
        NftPosition calldata position,
        bytes calldata // extraData
    ) external {
        // NFPG gauge accepts deposits via direct safeTransferFrom (empty data).
        // The gauge's onERC721Received sets beneficiary = from when
        // operator == from and data is empty.
        IERC721(address(position.nft)).safeTransferFrom(
            address(this), position.farm.stakingContract, position.tokenId
        );
    }

    function withdrawNft(
        NftPosition calldata position,
        bytes calldata // extraData
    ) external {
        INFPG(position.farm.stakingContract).withdraw(position.tokenId);
    }

    // No-op: trading fees are forwarded to the bribe contract by the gauge,
    // not to the sickle. Rewards are claimed via Merkl separately.
    function claim(
        NftPosition calldata, // position
        address[] memory, // rewardTokens
        uint128, // maxAmount0
        uint128, // maxAmount1
        bytes calldata // extraData
    ) external { }

    function isStaked(
        address user,
        NftPosition calldata position
    ) external view virtual override returns (bool) {
        return
            INFPG(position.farm.stakingContract).ownerOf(position.tokenId)
                == user;
    }

    function earned(
        address, // user
        NftPosition calldata,
        address[] memory rewardTokens
    ) external view virtual override returns (uint256[] memory) {
        return new uint256[](rewardTokens.length);
    }
}
