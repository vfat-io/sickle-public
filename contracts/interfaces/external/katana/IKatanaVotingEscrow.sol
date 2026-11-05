// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

struct KatanaLockedBalance {
    uint208 amount;
    uint48 start;
}

interface IKatanaVotingEscrow {
    function lockNFT() external view returns (address);

    function ownedTokens(
        address owner
    ) external view returns (uint256[] memory tokenIds);

    function locked(
        uint256 tokenId
    ) external view returns (KatanaLockedBalance memory);

    function beginWithdrawal(
        uint256 tokenId
    ) external;

    function resetVotesAndBeginWithdrawal(
        uint256 tokenId
    ) external;

    function cancelWithdrawalRequest(
        uint256 tokenId
    ) external;

    function withdraw(
        uint256 tokenId
    ) external;
}
