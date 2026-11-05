// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";
import { DelegateModule } from "contracts/modules/DelegateModule.sol";

/// @notice Claim parameters for PancakeSwap Infinity farm rewards
struct PancakeInfinityClaimParams {
    address token;
    uint256 amount;
    bytes32[] proof;
}

/// @notice PancakeSwap Infinity Distributor interface
interface IPancakeInfinityDistributor {
    function claim(PancakeInfinityClaimParams[] calldata claimParams) external;
}

/// @notice Extra data for claiming PancakeSwap Infinity farm rewards
struct PancakeInfinityFarmClaimExtraData {
    PancakeInfinityClaimParams[] claimParams;
    bytes feeClaimExtraData;
}

/// @title PancakeInfinityFarmConnector
/// @notice Connector for claiming CAKE rewards from PancakeSwap Infinity farms
/// @dev PancakeSwap Infinity uses a custom Merkle distributor (not Angle's Merkl)
/// Rewards are distributed every 8 hours based on fees earned by in-range positions
contract PancakeInfinityFarmConnector is INftFarmConnector, DelegateModule {
    ConnectorRegistry public immutable connectorRegistry;

    /// @notice PancakeSwap Infinity Distributor address
    /// @dev This is the contract that distributes CAKE rewards via Merkle proofs
    address public immutable distributor;

    constructor(ConnectorRegistry _connectorRegistry, address _distributor) {
        connectorRegistry = _connectorRegistry;
        distributor = _distributor;
    }

    /// @notice Claim CAKE rewards from PancakeSwap Infinity distributor and collect fees
    /// @param position The NFT position
    /// @param rewardTokens List of reward tokens to claim
    /// @param maxAmount0 Maximum amount of token0 fees to collect
    /// @param maxAmount1 Maximum amount of token1 fees to collect
    /// @param extraData Encoded PancakeInfinityFarmClaimExtraData
    function claim(
        NftPosition calldata position,
        address[] memory rewardTokens,
        uint128 maxAmount0,
        uint128 maxAmount1,
        bytes calldata extraData
    ) external override {
        PancakeInfinityFarmClaimExtraData memory claimExtraData =
            abi.decode(extraData, (PancakeInfinityFarmClaimExtraData));

        // Claim CAKE rewards from PancakeSwap Infinity distributor
        if (claimExtraData.claimParams.length > 0) {
            IPancakeInfinityDistributor(distributor).claim(
                claimExtraData.claimParams
            );
        }

        // Also collect swap fees from the position via the liquidity connector
        INftFarmConnector connector = INftFarmConnector(
            connectorRegistry.connectorOf(address(position.nft))
        );
        _delegateToConnector(
            address(connector),
            abi.encodeCall(
                INftFarmConnector.claim,
                (
                    position,
                    rewardTokens,
                    maxAmount0,
                    maxAmount1,
                    claimExtraData.feeClaimExtraData
                )
            )
        );
    }

    /// @notice Deposit NFT - no-op for PancakeSwap Infinity (no staking required)
    function depositExistingNft(
        NftPosition calldata,
        bytes calldata
    ) external override {}

    /// @notice Withdraw NFT - no-op for PancakeSwap Infinity (no staking required)
    function withdrawNft(
        NftPosition calldata,
        bytes calldata
    ) external override {}

    /// @notice Get earned rewards - returns zeros (off-chain calculation)
    /// @dev PancakeSwap Infinity rewards are calculated off-chain via their API
    /// Use: GET https://infinity.pancakeswap.com/farms/users/{chainId}/{address}/{timestamp}
    function earned(
        address,
        NftPosition calldata,
        address[] memory rewardTokens
    ) external pure override returns (uint256[] memory) {
        return new uint256[](rewardTokens.length);
    }

    /// @notice Check if position is staked - always false (no staking required)
    function isStaked(
        address,
        NftPosition calldata
    ) external pure override returns (bool) {
        return false;
    }
}
