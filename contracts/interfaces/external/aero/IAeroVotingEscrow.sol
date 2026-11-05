// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice Aero (Dromos MetaDEX) `VotingEscrow` (sAERO), reduced to the
/// stake and enumeration surface a Sickle connector needs on top of ERC-721.
/// @dev Declared from the verified ABI of the Base deployment
/// (0xBF7977E1521e9a3032bf7243Ee4712f311f13915).
interface IAeroVotingEscrow {
    /// @param end Unstake timestamp; zero when `isPermanent`.
    struct StakedBalance {
        uint128 amount;
        uint48 end;
        bool isPermanent;
    }

    function TOKEN() external view returns (address);

    function VOTER() external view returns (address);

    function staked(
        uint256 tokenId
    ) external view returns (StakedBalance memory);

    /// @notice Add `value` to the stake, keeping its end and mode. Owner or
    /// approved only; reverts on an expired decaying stake.
    function increaseStakeAmount(
        uint256 tokenId,
        uint128 value
    ) external;

    function ownerOf(
        uint256 tokenId
    ) external view returns (address);

    function balanceOf(
        address owner
    ) external view returns (uint256);

    function tokenOfOwnerByIndex(
        address owner,
        uint256 index
    ) external view returns (uint256);
}
