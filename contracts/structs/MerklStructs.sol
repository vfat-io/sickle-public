// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

struct MerklClaimExtraData {
    address[] claimTokens;
    uint256[] amounts;
    bytes32[][] proofs;
    bytes feeClaimExtraData;
}
