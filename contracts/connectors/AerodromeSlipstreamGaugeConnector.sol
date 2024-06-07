// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interfaces/IFarmConnector.sol";
import "../interfaces/external/aerodrome/ICLGauge.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Enumerable } from
    "@openzeppelin/contracts/interfaces/IERC721Enumerable.sol";

// Either enter the existing token ID in case of increase/compound,
// or the balance index in case of deposit
struct AerodromeSlipstreamGaugeDepositExtraData {
    uint256 tokenId;
    // User's existing NFT balance in the Sickle, typically 0
    uint256 tokenBalance;
}

struct AerodromeSlipstreamGaugeClaimExtraData {
    uint256 tokenId;
}

struct AerodromeSlipstreamGaugeWithdrawExtraData {
    uint256 tokenId;
}

contract AerodromeSlipstreamGaugeConnector is IFarmConnector {
    function deposit(
        address target,
        address token,
        bytes memory extraData
    ) external payable override {
        AerodromeSlipstreamGaugeDepositExtraData memory data =
            abi.decode(extraData, (AerodromeSlipstreamGaugeDepositExtraData));
        if (data.tokenId == 0) {
            data.tokenId = IERC721Enumerable(token).tokenOfOwnerByIndex(
                address(this), data.tokenBalance
            );
        }

        IERC721(token).approve(target, data.tokenId);
        ICLGauge(target).deposit(data.tokenId);
    }

    function withdraw(
        address target,
        uint256, // amount
        bytes memory extraData
    ) external override {
        AerodromeSlipstreamGaugeWithdrawExtraData memory data =
            abi.decode(extraData, (AerodromeSlipstreamGaugeWithdrawExtraData));
        ICLGauge(target).withdraw(data.tokenId);
    }

    function claim(address target, bytes memory extraData) external override {
        AerodromeSlipstreamGaugeClaimExtraData memory data =
            abi.decode(extraData, (AerodromeSlipstreamGaugeClaimExtraData));
        ICLGauge(target).getReward(data.tokenId);
    }
}
