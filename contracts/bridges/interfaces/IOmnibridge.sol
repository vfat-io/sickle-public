// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @title IOmnibridgeReceiver
/// @notice Destination callback an Omnibridge (xDai TokenBridge + AMB)
/// mediator invokes on the recipient of a `relayTokensAndCall` transfer.
/// @dev Upstream names this interface `IERC20Receiver`; renamed here because
/// it is an Omnibridge convention, not an ERC. Selector is unchanged:
/// `onTokenBridged(address,uint256,bytes)` == `0xdb7af854`.
///
/// The mediator delivers the tokens *before* the callback and invokes it
/// with a bare `.call` whose return value is discarded. See
/// `_receiverCallback` in `BasicOmnibridge`: a reverting receiver keeps the
/// tokens, it does not bounce the delivery.
interface IOmnibridgeReceiver {
    /// @param token Local ERC20 the mediator just delivered to the recipient.
    /// @param value Amount delivered.
    /// @param data Payload supplied by the sender on the origin chain.
    function onTokenBridged(
        address token,
        uint256 value,
        bytes calldata data
    ) external;
}

/// @title IOmnibridgeMediator
/// @notice The subset of `BasicOmnibridge` an integration needs to audit the
/// pairing between the two sides of the bridge.
interface IOmnibridgeMediator {
    /// @notice The AMB this mediator sends through and is called by.
    function bridgeContract() external view returns (address);

    /// @notice The mediator this one is paired with on the other chain.
    function mediatorContractOnOtherSide() external view returns (address);
}

/// @title IOmnibridgeAmb
/// @notice Execution-context accessors on the Arbitrary Message Bridge.
/// @dev All three are set immediately before the AMB calls the executor and
/// zeroed immediately after (`MessageProcessor._passMessage`), and the AMB
/// refuses to process a nested message while one is in flight. They are
/// therefore a sound origin proof for the duration of a callback, and read
/// back as zero at any other time.
interface IOmnibridgeAmb {
    /// @notice Address that sent the message on the origin chain.
    function messageSender() external view returns (address);

    /// @notice Chain id the in-flight message originated on.
    /// @dev Declared `bytes32` in the upstream `IAMB` but written as a
    /// `uint256` chain id by the implementation; both are one word, so the
    /// numeric type is the honest one to decode against.
    function messageSourceChainId() external view returns (uint256);

    /// @notice Id of the in-flight message.
    function messageId() external view returns (bytes32);
}
