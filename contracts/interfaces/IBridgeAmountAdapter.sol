// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @title IBridgeAmountAdapter
/// @notice Source-side bridge adapter interface for calls where the bridge
/// amount is only known after an upstream swap has executed.
interface IBridgeAmountAdapter {
    function bridgeExactAmount(
        address bridgeToken,
        uint256 amount,
        bytes calldata params
    ) external payable returns (bytes memory result);
}
