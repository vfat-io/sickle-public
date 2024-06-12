// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { Sickle } from "contracts/Sickle.sol";

contract NftTransferLib {
    /// @dev Transfers the ERC721 NFT with {tokenId} from the user to the Sickle
    function transferErc721FromUser(
        address nftContractAddress,
        uint256 tokenId
    ) external {
        IERC721(nftContractAddress).safeTransferFrom(
            Sickle(payable(address(this))).owner(), address(this), tokenId
        );
    }

    /// @dev Transfers the ERC721 NFT with {tokenId} from the Sickle to the user
    function transferErc721ToUser(
        address nftContractAddress,
        uint256 tokenId
    ) external {
        IERC721(nftContractAddress).safeTransferFrom(
            address(this), Sickle(payable(address(this))).owner(), tokenId
        );
    }

    /// @dev Transfers the ERC1155 NFT with {tokenId} from the user to Sickle
    function transferErc1155FromUser(
        address nftContractAddress,
        uint256 tokenId,
        uint256 amount
    ) external {
        IERC1155(nftContractAddress).safeTransferFrom(
            Sickle(payable(address(this))).owner(),
            address(this),
            tokenId,
            amount,
            ""
        );
    }

    /// @dev Transfers the ERC1155 NFT with {tokenId} from Sickle to the user
    function transferErc1155ToUser(
        address nftContractAddress,
        uint256 tokenId,
        uint256 amount
    ) external {
        IERC1155(nftContractAddress).safeTransferFrom(
            address(this),
            Sickle(payable(address(this))).owner(),
            tokenId,
            amount,
            ""
        );
    }
}
