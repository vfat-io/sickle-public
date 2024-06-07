// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./modules/NftTransferModule.sol";

contract SweepStrategy is NftTransferModule {
    error InvalidInputLength(); //0x7db491eb

    constructor(
        SickleFactory factory_,
        FeesLib feesLib_,
        address wrappedNativeAddress_
    ) NftTransferModule(factory_, feesLib_, wrappedNativeAddress_) { }

    function sweepTokens(address[] memory tokens) public {
        Sickle sickle = getSickle(msg.sender);

        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(this);
        data[0] = abi.encodeCall(this._sickle_transfer_tokens_to_user, (tokens));

        sickle.multicall(targets, data);
    }

    function sweepErc721(
        address[] memory tokens,
        uint256[] memory tokenIds
    ) public {
        Sickle sickle = getSickle(msg.sender);

        if (tokens.length != tokenIds.length) {
            revert InvalidInputLength();
        }

        address[] memory targets = new address[](tokens.length);
        bytes[] memory data = new bytes[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            targets[i] = address(this);
            data[i] = abi.encodeCall(
                this._sickle_transfer_nft_to_user, (tokens[i], tokenIds[i])
            );
        }

        sickle.multicall(targets, data);
    }

    function sweepErc1155(
        address[] memory tokens,
        uint256[] memory tokenIds,
        uint256[] memory amounts
    ) public {
        Sickle sickle = getSickle(msg.sender);

        if (tokens.length != tokenIds.length || tokens.length != amounts.length)
        {
            revert InvalidInputLength();
        }

        address[] memory targets = new address[](tokens.length);
        bytes[] memory data = new bytes[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            targets[i] = address(this);
            data[i] = abi.encodeCall(
                this._sickle_transfer_erc1155_to_user,
                (tokens[i], tokenIds[i], amounts[i])
            );
        }

        sickle.multicall(targets, data);
    }
}
