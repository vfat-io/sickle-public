// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

enum ExitKind {
    Farm,
    Nft,
    Erc6909,
    Bin
}

/// @notice An existing owner-exit call, including its function selector.
struct ExitCall {
    ExitKind kind;
    bytes data;
}
