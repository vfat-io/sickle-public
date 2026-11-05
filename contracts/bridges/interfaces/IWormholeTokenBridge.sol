// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IWormhole {
    struct Signature {
        bytes32 r;
        bytes32 s;
        uint8 v;
        uint8 guardianIndex;
    }

    struct VM {
        uint8 version;
        uint32 timestamp;
        uint32 nonce;
        uint16 emitterChainId;
        bytes32 emitterAddress;
        uint64 sequence;
        uint8 consistencyLevel;
        bytes payload;
        uint32 guardianSetIndex;
        Signature[] signatures;
        bytes32 hash;
    }

    function parseVM(
        bytes memory encodedVM
    ) external pure returns (VM memory vm);
}

/// @title IWormholeTokenBridge
/// @notice Minimal interface for the Wormhole Token Bridge, used by
/// Executor Relay adapters to redeem cross-chain token transfers.
interface IWormholeTokenBridge {
    struct TransferWithPayload {
        uint8 payloadID;
        uint256 amount;
        bytes32 tokenAddress;
        uint16 tokenChain;
        bytes32 to;
        uint16 toChain;
        bytes32 fromAddress;
        bytes payload;
    }

    /// @notice Complete a transfer-with-payload (type 3), verifying the VAA
    /// and releasing/minting tokens to msg.sender.
    /// @dev Reverts if the VAA is invalid, already redeemed, or if the
    /// `to` field does not match msg.sender.
    /// @param encodedVm Signed Wormhole VAA bytes
    /// @return The raw Token Bridge transfer payload
    function completeTransferWithPayload(
        bytes memory encodedVm
    ) external returns (bytes memory);

    /// @notice Decode a Token Bridge type-3 transfer payload.
    /// @param encoded Encoded Token Bridge transfer payload
    /// @return transfer Decoded transfer-with-payload message
    function parseTransferWithPayload(bytes memory encoded)
        external
        pure
        returns (TransferWithPayload memory transfer);

    /// @notice Look up the local wrapped asset for a foreign token.
    /// @param tokenChain Wormhole chain ID where the token is native
    /// @param tokenAddress Token address on the native chain (bytes32)
    /// @return Local ERC-20 address (address(0) if not attested)
    function wrappedAsset(
        uint16 tokenChain,
        bytes32 tokenAddress
    ) external view returns (address);

    /// @notice The Wormhole chain ID of this chain.
    function chainId() external view returns (uint16);

    /// @notice Address of the Wormhole Core contract used by this Token Bridge.
    function wormhole() external view returns (IWormhole);
}
