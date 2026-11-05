// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Cumulative Merkle claims for FABLES emissions, separate from USDG
///         incentives and from the swap fees stakers assign to voters.
interface IFablesEmissionStream {
    enum Kind {
        LIQUID,
        LOCK
    }

    function keyOf(
        Kind kind,
        uint256 id
    ) external pure returns (bytes32);

    function claimedOf(
        bytes32 key
    ) external view returns (uint256);

    /// @dev LIQUID pays address(uint160(id)), regardless of msg.sender.
    function claim(
        Kind kind,
        uint256 id,
        uint256 cumulative,
        bytes32[] calldata proof
    ) external returns (uint256 amount);
}
