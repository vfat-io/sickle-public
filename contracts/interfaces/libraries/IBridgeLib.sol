// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IBridgeLib {
    error ZeroBridgeAmount();
    error NotDelegatecall();
    error BridgeFailed(bytes reason);
    error BridgeDidNotConsumeTokens();

    function bridge(
        address bridgeContract,
        bytes calldata bridgeCalldata,
        address token,
        uint256 amount
    ) external payable;
}
