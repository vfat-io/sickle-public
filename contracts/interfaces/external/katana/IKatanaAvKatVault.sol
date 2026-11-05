// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IKatanaAvKatVault {
    function asset() external view returns (address);

    function convertToShares(
        uint256 assets
    ) external view returns (uint256);

    function depositTokenId(
        uint256 tokenId,
        address receiver
    ) external returns (uint256);
}
