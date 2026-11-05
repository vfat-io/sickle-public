// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

struct StargateSendParam {
    uint32 dstEid;
    bytes32 to;
    uint256 amountLD;
    uint256 minAmountLD;
    bytes extraOptions;
    bytes composeMsg;
    bytes oftCmd;
}

struct StargateMessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct StargateMessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    StargateMessagingFee fee;
}

struct StargateOFTLimit {
    uint256 minAmountLD;
    uint256 maxAmountLD;
}

struct StargateOFTFeeDetail {
    int256 feeAmountLD;
    string description;
}

struct StargateOFTReceipt {
    uint256 amountSentLD;
    uint256 amountReceivedLD;
}

struct StargateTicket {
    uint72 ticketId;
    bytes passengerBytes;
}

/// @notice Minimal Stargate V2 source interface used by the exact-amount
/// adapter. Pool and OFT source contracts expose the same surface.
interface IStargateV2 {
    function token() external view returns (address);

    function quoteOFT(
        StargateSendParam calldata sendParam
    )
        external
        view
        returns (
            StargateOFTLimit memory limit,
            StargateOFTFeeDetail[] memory feeDetails,
            StargateOFTReceipt memory receipt
        );

    function quoteSend(
        StargateSendParam calldata sendParam,
        bool payInLzToken
    ) external view returns (StargateMessagingFee memory fee);

    function sendToken(
        StargateSendParam calldata sendParam,
        StargateMessagingFee calldata fee,
        address refundAddress
    )
        external
        payable
        returns (
            StargateMessagingReceipt memory messageReceipt,
            StargateOFTReceipt memory oftReceipt,
            StargateTicket memory ticket
        );
}
