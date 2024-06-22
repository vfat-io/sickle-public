// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    RebalanceConfig,
    RebalanceKey,
    NftInfo,
    IRebalanceRegistry
} from "contracts/interfaces/IRebalanceRegistry.sol";
import { RebalanceRegistry } from "contracts/RebalanceRegistry.sol";
import { IFarmConnector } from "contracts/interfaces/IFarmConnector.sol";
import {
    IUniswapV3Pool,
    IUniswapV3PoolState,
    IUniswapV3PoolImmutables
} from "contracts/interfaces/external/uniswap/IUniswapV3Pool.sol";
import { INonfungiblePositionManager } from
    "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import { StrategyModule } from "contracts/modules/StrategyModule.sol";
import { ZapLib, ZapInData, ZapOutData } from "contracts/libraries/ZapLib.sol";
import { FeesLib } from "contracts/libraries/FeesLib.sol";
import { TransferLib } from "contracts/libraries/TransferLib.sol";
import { RebalanceLib } from "contracts/libraries/RebalanceLib.sol";
import { SwapData } from "contracts/interfaces/ILiquidityConnector.sol";
import { SickleFactory } from "contracts/SickleFactory.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { Sickle } from "contracts/Sickle.sol";

library RebalanceStrategyFees {
    bytes4 constant Harvest = bytes4(keccak256("RebalanceHarvestFee"));
    bytes4 constant HarvestFor = bytes4(keccak256("RebalanceHarvestForFee"));
    bytes4 constant RebalanceLow = bytes4(keccak256("RebalanceLowFee"));
    bytes4 constant RebalanceMid = bytes4(keccak256("RebalanceMidFee"));
    bytes4 constant RebalanceHigh = bytes4(keccak256("RebalanceHighFee"));
}

contract RebalanceStrategy is RebalanceRegistry, StrategyModule {
    error TokenOutRequired();
    error RebalanceConfigNotSet();
    error TickWithinRange();
    error TickOutsideMaxRange();
    error NftSupplyChanged();

    struct DepositParams {
        address stakingContractAddress;
        address[] tokensIn;
        uint256[] amountsIn;
        ZapInData zapData;
        bytes extraData;
    }

    struct WithdrawParams {
        address stakingContractAddress;
        bytes extraData;
        ZapOutData zapData;
        address[] tokensOut;
    }

    struct HarvestParams {
        address stakingContractAddress;
        SwapData[] swaps;
        bytes extraData;
        address[] tokensOut;
    }

    struct Libraries {
        ZapLib zapLib;
        FeesLib feesLib;
        TransferLib transferLib;
        RebalanceLib rebalanceLib;
    }

    ZapLib public immutable zapLib;
    FeesLib public immutable feesLib;
    TransferLib public immutable transferLib;
    RebalanceLib public immutable rebalanceLib;

    address public immutable strategyAddress;

    constructor(
        SickleFactory factory,
        ConnectorRegistry connectorRegistry,
        Libraries memory libraries
    ) StrategyModule(factory, connectorRegistry) {
        strategyAddress = address(this);
        zapLib = libraries.zapLib;
        feesLib = libraries.feesLib;
        transferLib = libraries.transferLib;
        rebalanceLib = libraries.rebalanceLib;
    }

    /* External functions */

    function setRebalanceConfig(
        INonfungiblePositionManager nftManager,
        uint256 tokenId,
        RebalanceConfig calldata config
    ) external {
        Sickle sickle = getSickle(msg.sender);
        RebalanceKey memory key = RebalanceKey(sickle, nftManager, tokenId);
        _set_rebalance_config(key, config);
    }

    function unsetRebalanceConfig(
        INonfungiblePositionManager nftManager,
        uint256 tokenId
    ) external {
        Sickle sickle = getSickle(msg.sender);
        RebalanceKey memory key = RebalanceKey(sickle, nftManager, tokenId);
        _unset_rebalance_config(key);
    }

    function rebalanceFor(
        address sickleAddress,
        NftInfo calldata nftInfo,
        HarvestParams calldata harvestParams,
        WithdrawParams calldata withdrawParams,
        DepositParams calldata depositParams,
        address[] memory sweepTokens
    ) external checkOwnerOrApproved(sickleAddress) {
        Sickle sickle = Sickle(payable(sickleAddress));

        if (withdrawParams.tokensOut.length == 0) {
            revert TokenOutRequired();
        }

        RebalanceConfig memory config = getRebalanceConfig(
            RebalanceKey(sickle, nftInfo.nftManager, nftInfo.tokenId)
        );

        if (config.tickLow == 0 && config.tickHigh == 0) {
            revert RebalanceConfigNotSet();
        }

        int24 tick = _get_curent_tick(nftInfo.pool);

        if (tick >= config.tickLow && tick <= config.tickHigh) {
            revert TickWithinRange();
        }
        if (tick < config.minTickLow || tick > config.maxTickHigh) {
            revert TickOutsideMaxRange();
        }

        uint256 nftTotalSupply = nftInfo.nftManager.totalSupply();

        address[] memory targets = new address[](9);
        bytes[] memory data = new bytes[](9);

        targets[0] =
            connectorRegistry.connectorOf(harvestParams.stakingContractAddress);
        data[0] = abi.encodeCall(
            IFarmConnector.claim,
            (harvestParams.stakingContractAddress, harvestParams.extraData)
        );

        targets[1] = address(feesLib);
        data[1] = abi.encodeCall(
            FeesLib.chargeFees,
            (
                strategyAddress,
                RebalanceStrategyFees.HarvestFor,
                harvestParams.tokensOut
            )
        );

        targets[2] =
            connectorRegistry.connectorOf(withdrawParams.stakingContractAddress);
        data[2] = abi.encodeCall(
            IFarmConnector.withdraw,
            (
                withdrawParams.stakingContractAddress,
                withdrawParams.zapData.removeLiquidityData.lpAmountIn,
                withdrawParams.extraData
            )
        );

        targets[3] = address(zapLib);
        data[3] = abi.encodeCall(ZapLib.zapOut, (withdrawParams.zapData));

        targets[4] = address(feesLib);
        data[4] = abi.encodeCall(
            FeesLib.chargeFees,
            (
                strategyAddress,
                _get_rebalance_fee(nftInfo.pool),
                withdrawParams.tokensOut
            )
        );

        targets[5] = address(zapLib);
        data[5] = abi.encodeCall(ZapLib.zapIn, (depositParams.zapData));

        targets[6] = address(rebalanceLib);
        data[6] = abi.encodeCall(
            RebalanceLib.resetRebalanceConfig,
            (IRebalanceRegistry(strategyAddress), nftInfo)
        );

        targets[7] =
            connectorRegistry.connectorOf(depositParams.stakingContractAddress);
        data[7] = abi.encodeCall(
            IFarmConnector.deposit,
            (
                depositParams.stakingContractAddress,
                depositParams.zapData.addLiquidityData.lpToken,
                depositParams.extraData
            )
        );

        if (sweepTokens.length > 0) {
            targets[8] = address(transferLib);
            data[8] =
                abi.encodeCall(TransferLib.transferTokensToUser, (sweepTokens));
        }

        sickle.multicall(targets, data);

        if (nftTotalSupply != nftInfo.nftManager.totalSupply()) {
            revert NftSupplyChanged();
        }
    }

    function rebalance(
        IUniswapV3Pool pool,
        HarvestParams calldata harvestParams,
        WithdrawParams calldata withdrawParams,
        DepositParams calldata depositParams,
        address[] memory sweepTokens
    ) external {
        if (withdrawParams.tokensOut.length == 0) {
            revert TokenOutRequired();
        }

        Sickle sickle = getSickle(msg.sender);

        address[] memory targets = new address[](8);
        bytes[] memory data = new bytes[](8);

        targets[0] =
            connectorRegistry.connectorOf(harvestParams.stakingContractAddress);
        data[0] = abi.encodeCall(
            IFarmConnector.claim,
            (harvestParams.stakingContractAddress, harvestParams.extraData)
        );

        targets[1] = address(feesLib);
        data[1] = abi.encodeCall(
            FeesLib.chargeFees,
            (
                strategyAddress,
                RebalanceStrategyFees.Harvest,
                harvestParams.tokensOut
            )
        );

        targets[2] =
            connectorRegistry.connectorOf(withdrawParams.stakingContractAddress);
        data[2] = abi.encodeCall(
            IFarmConnector.withdraw,
            (
                withdrawParams.stakingContractAddress,
                withdrawParams.zapData.removeLiquidityData.lpAmountIn,
                withdrawParams.extraData
            )
        );

        targets[3] = address(zapLib);
        data[3] = abi.encodeCall(ZapLib.zapOut, (withdrawParams.zapData));

        targets[4] = address(feesLib);
        data[4] = abi.encodeCall(
            FeesLib.chargeFees,
            (
                strategyAddress,
                _get_rebalance_fee(pool),
                withdrawParams.tokensOut
            )
        );

        targets[5] = address(zapLib);
        data[5] = abi.encodeCall(ZapLib.zapIn, (depositParams.zapData));

        targets[6] =
            connectorRegistry.connectorOf(depositParams.stakingContractAddress);
        data[6] = abi.encodeCall(
            IFarmConnector.deposit,
            (
                depositParams.stakingContractAddress,
                depositParams.zapData.addLiquidityData.lpToken,
                depositParams.extraData
            )
        );

        if (sweepTokens.length > 0) {
            targets[7] = address(transferLib);
            data[7] =
                abi.encodeCall(TransferLib.transferTokensToUser, (sweepTokens));
        }

        sickle.multicall(targets, data);
    }

    /* Internal functions */

    // Tick is the 2nd field in slot0, the rest can vary
    function _get_curent_tick(IUniswapV3Pool pool) internal returns (int24) {
        (, bytes memory result) =
            address(pool).call(abi.encodeCall(IUniswapV3PoolState.slot0, ()));

        int24 tick;

        assembly {
            tick := mload(add(add(result, 32), 32))
        }

        return tick;
    }

    function _get_rebalance_fee(IUniswapV3Pool pool)
        internal
        view
        returns (bytes4)
    {
        uint24 fee = IUniswapV3PoolImmutables(pool).fee();
        if (fee <= 500) {
            return RebalanceStrategyFees.RebalanceLow;
        } else if (fee <= 3000) {
            return RebalanceStrategyFees.RebalanceMid;
        } else {
            return RebalanceStrategyFees.RebalanceHigh;
        }
    }
}
