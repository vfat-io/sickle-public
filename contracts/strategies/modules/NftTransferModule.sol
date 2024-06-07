// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import "./TransferModule.sol";

contract NftTransferModule is TransferModule {
    constructor(
        SickleFactory factory_,
        FeesLib feesLib_,
        address wrappedNativeAddress_
    ) TransferModule(factory_, feesLib_, wrappedNativeAddress_) { }

    /// @dev Transfers the ERC721 NFT with {tokenId} from the user to the Sickle
    function _sickle_transfer_nft_from_user(
        address nftContractAddress,
        uint256 tokenId
    ) external onlyRegisteredSickle {
        IERC721(nftContractAddress).safeTransferFrom(
            Sickle(payable(address(this))).owner(), address(this), tokenId
        );
    }

    /// @dev Transfers the ERC721 NFT with {tokenId} from the Sickle to the user
    function _sickle_transfer_nft_to_user(
        address nftContractAddress,
        uint256 tokenId
    ) external onlyRegisteredSickle {
        IERC721(nftContractAddress).safeTransferFrom(
            address(this), Sickle(payable(address(this))).owner(), tokenId
        );
    }

    /// @dev Transfers the ERC1155 NFT with {tokenId} from the user to Sickle
    function _sickle_transfer_erc1155_from_user(
        address nftContractAddress,
        uint256 tokenId,
        uint256 amount
    ) external onlyRegisteredSickle {
        IERC1155(nftContractAddress).safeTransferFrom(
            Sickle(payable(address(this))).owner(),
            address(this),
            tokenId,
            amount,
            ""
        );
    }

    /// @dev Transfers the ERC1155 NFT with {tokenId} from Sickle to the user
    function _sickle_transfer_erc1155_to_user(
        address nftContractAddress,
        uint256 tokenId,
        uint256 amount
    ) external onlyRegisteredSickle {
        IERC1155(nftContractAddress).safeTransferFrom(
            address(this),
            Sickle(payable(address(this))).owner(),
            tokenId,
            amount,
            ""
        );
    }
}
