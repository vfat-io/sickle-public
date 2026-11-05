// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import {
    IFablesEmissionStream
} from "contracts/interfaces/external/fables/IFablesEmissionStream.sol";
import {
    FablesRewardsConnector
} from "contracts/connectors/fables/FablesRewardsConnector.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";

/// @dev Use the same envelope for every farm action. Compound forwards harvest
///      extraData to unstake/restake too. lpExtraData is FablesExtraData or the
///      extended FablesStakeExtraData; its liquidity=0 means all eligible
/// shares. cumulativeAmount=0 with an empty proof skips emissions, including on
///      withdrawals when no fresh proof is available.
struct FablesEmissionExtraData {
    uint256 cumulativeAmount;
    bytes32[] proof;
    bytes lpExtraData;
}

/// @notice Native FABLES claims plus hook staking, unstaking and swap fees.
/// @dev Delegated by the Sickle: the LIQUID id and payout account are always
///      address(this). No mutable storage is added to the Sickle. The immutable
///      stream is also the registered farm target; the hook remains
/// position.nft.
contract FablesEmissionsConnector is FablesRewardsConnector {
    error InvalidEmissionFarm();

    IFablesEmissionStream public immutable emissionStream;

    constructor(
        ConnectorRegistry connectorRegistry_,
        IFablesEmissionStream emissionStream_
    ) FablesRewardsConnector(connectorRegistry_) {
        if (address(emissionStream_) == address(0)) {
            revert InvalidEmissionFarm();
        }
        emissionStream = emissionStream_;
    }

    function claim(
        NftPosition calldata position,
        address[] memory rewardTokens,
        uint128 maxAmount0,
        uint128 maxAmount1,
        bytes calldata extraData
    ) external override {
        FablesEmissionExtraData memory params = _params(position, extraData);
        uint256 accountId = uint256(uint160(address(this)));
        bytes32 key = emissionStream.keyOf(
            IFablesEmissionStream.Kind.LIQUID, accountId
        );
        // Already paid leaves are normal after a keeper/another range claims.
        // A zero-length proof can be valid for a single-leaf tree.
        if (params.cumulativeAmount > emissionStream.claimedOf(key)) {
            emissionStream.claim(
                IFablesEmissionStream.Kind.LIQUID,
                accountId,
                params.cumulativeAmount,
                params.proof
            );
        }
        _delegateToLp(
            position,
            abi.encodeCall(
                INftFarmConnector.claim,
                (
                    position,
                    rewardTokens,
                    maxAmount0,
                    maxAmount1,
                    params.lpExtraData
                )
            )
        );
    }

    function depositExistingNft(
        NftPosition calldata position,
        bytes calldata extraData
    ) external override {
        FablesEmissionExtraData memory params = _params(position, extraData);
        _delegateToLp(
            position,
            abi.encodeCall(
                INftFarmConnector.depositExistingNft,
                (position, params.lpExtraData)
            )
        );
    }

    function withdrawNft(
        NftPosition calldata position,
        bytes calldata extraData
    ) external override {
        FablesEmissionExtraData memory params = _params(position, extraData);
        _delegateToLp(
            position,
            abi.encodeCall(
                INftFarmConnector.withdrawNft, (position, params.lpExtraData)
            )
        );
    }

    function _params(
        NftPosition calldata position,
        bytes calldata extraData
    ) internal view returns (FablesEmissionExtraData memory) {
        if (
            position.farm.stakingContract != address(emissionStream)
                || position.farm.poolIndex != 0
        ) {
            revert InvalidEmissionFarm();
        }
        return abi.decode(extraData, (FablesEmissionExtraData));
    }
}
