// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IAeroClGauge {
    function nft() external view returns (address);

    function deposit(
        uint256 tokenId
    ) external;

    function withdraw(
        uint256 tokenId
    ) external;

    function claimEmissions(
        address account,
        address recipient,
        uint256[] calldata tokenIds
    ) external;

    function earned(
        address account,
        uint256[] memory tokenIds
    ) external view returns (uint256);

    function stakedContains(
        address depositor,
        uint256 tokenId
    ) external view returns (bool);
}
