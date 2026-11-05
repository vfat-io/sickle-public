// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import {
    INftLiquidityConnector
} from "contracts/interfaces/INftLiquidityConnector.sol";
import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import {
    NftPoolKey,
    NftPoolInfo
} from "contracts/structs/NftLiquidityStructs.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";

struct NftPositionInfo {
    uint128 liquidity;
    int24 tickLower;
    int24 tickUpper;
    bool isStaked;
    uint256 fees0;
    uint256 fees1;
    uint256[] tokenRewards;
}

struct ERC20PositionInfo {
    uint256 balance;
    bool isStaked;
    uint256[] tokenRewards;
}

contract ConnectorLens {
    struct LiquidityData {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    struct FeesData {
        uint256 fees0;
        uint256 fees1;
    }

    function getPositionInfo(
        ConnectorRegistry registry,
        address poolFactory,
        address user,
        NftPosition calldata position,
        address[] calldata rewardTokens
    ) external view returns (NftPositionInfo memory, NftPoolKey memory) {
        NftPoolKey memory poolKey = _get_pool_key(
            registry, poolFactory, address(position.nft), position.tokenId
        );
        NftPositionInfo memory positionInfo = _get_position_info(
            registry, poolFactory, user, position, rewardTokens
        );

        return (positionInfo, poolKey);
    }

    function _get_pool_key(
        ConnectorRegistry registry,
        address poolFactory,
        address nftManager,
        uint256 tokenId
    ) internal view returns (NftPoolKey memory) {
        address connectorAddress = registry.connectorOf(nftManager);
        return INftLiquidityConnector(connectorAddress)
            .positionPoolKey(poolFactory, nftManager, tokenId);
    }

    function _get_position_info(
        ConnectorRegistry registry,
        address poolFactory,
        address user,
        NftPosition calldata position,
        address[] calldata rewardTokens
    ) internal view returns (NftPositionInfo memory) {
        address connectorAddress = registry.connectorOf(address(position.nft));

        LiquidityData memory liquidityData =
            _get_liquidity_data(connectorAddress, position);

        NftPoolKey memory poolKey = INftLiquidityConnector(connectorAddress)
            .positionPoolKey(
                poolFactory, address(position.nft), position.tokenId
            );

        FeesData memory feesData = _get_fees_data(
            connectorAddress,
            address(position.nft),
            poolKey.poolAddress,
            position.tokenId
        );

        address farmConnectorAddress =
            registry.connectorOf(address(position.farm.stakingContract));

        bool isStaked =
            INftFarmConnector(farmConnectorAddress).isStaked(user, position);
        uint256[] memory tokenRewards = INftFarmConnector(farmConnectorAddress)
            .earned(user, position, rewardTokens);

        return NftPositionInfo({
            liquidity: liquidityData.liquidity,
            tickLower: liquidityData.tickLower,
            tickUpper: liquidityData.tickUpper,
            isStaked: isStaked,
            fees0: feesData.fees0,
            fees1: feesData.fees1,
            tokenRewards: tokenRewards
        });
    }

    function _get_liquidity_data(
        address connectorAddress,
        NftPosition calldata position
    ) internal view returns (LiquidityData memory) {
        (int24 tickLower, int24 tickUpper, uint128 liquidity) =
        INftLiquidityConnector(connectorAddress).positionLiquidity(
            address(position.nft), position.tokenId
        );

        return LiquidityData({
            tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity
        });
    }

    function _get_fees_data(
        address connectorAddress,
        address nft,
        address poolAddress,
        uint256 tokenId
    ) internal view returns (FeesData memory) {
        (uint256 fees0, uint256 fees1) = INftLiquidityConnector(
                connectorAddress
            ).earnedFees(nft, poolAddress, tokenId);

        return FeesData({ fees0: fees0, fees1: fees1 });
    }

    function getPoolInfo(
        ConnectorRegistry registry,
        address nftManager,
        address pool,
        bytes32 poolId
    ) external view returns (NftPoolInfo memory poolInfo) {
        address connectorAddress = registry.connectorOf(nftManager);
        INftLiquidityConnector connector =
            INftLiquidityConnector(connectorAddress);

        poolInfo = connector.poolInfo(pool, poolId);
    }

    function getERC20PositionInfo(
        ConnectorRegistry registry,
        Farm calldata farm,
        address user,
        address[] calldata rewardTokens
    ) external view returns (ERC20PositionInfo memory) {
        address connectorAddress = registry.connectorOf(farm.stakingContract);
        uint256 balance = IFarmConnector(connectorAddress).balanceOf(farm, user);
        bool isStaked = IFarmConnector(connectorAddress).isStaked(farm, user);
        uint256[] memory tokenRewards =
            IFarmConnector(connectorAddress).earned(farm, user, rewardTokens);

        return ERC20PositionInfo({
            balance: balance, isStaked: isStaked, tokenRewards: tokenRewards
        });
    }
}
