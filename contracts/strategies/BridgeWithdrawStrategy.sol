// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    StrategyModule,
    SickleFactory,
    Sickle,
    ConnectorRegistry
} from "contracts/modules/StrategyModule.sol";
import { IFarmConnector } from "contracts/interfaces/IFarmConnector.sol";
import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import {
    INftLiquidityConnector
} from "contracts/interfaces/INftLiquidityConnector.sol";
import { IFeesLib } from "contracts/interfaces/libraries/IFeesLib.sol";
import { ISwapLib } from "contracts/interfaces/libraries/ISwapLib.sol";
import { ITransferLib } from "contracts/interfaces/libraries/ITransferLib.sol";
import { IZapLib } from "contracts/interfaces/libraries/IZapLib.sol";
import { INftZapLib } from "contracts/interfaces/libraries/INftZapLib.sol";
import { IBridgeLib } from "contracts/interfaces/libraries/IBridgeLib.sol";
import {
    IWormholeCctpLib
} from "contracts/interfaces/libraries/IWormholeCctpLib.sol";
import {
    IWormholeExecutorLib
} from "contracts/interfaces/libraries/IWormholeExecutorLib.sol";
import {
    Farm,
    WithdrawParams,
    HarvestParams
} from "contracts/structs/FarmStrategyStructs.sol";
import {
    NftPosition,
    NftWithdraw,
    NftHarvest
} from "contracts/structs/NftFarmStrategyStructs.sol";
import {
    INonfungiblePositionManager
} from "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";

library BridgeWithdrawStrategyFees {
    bytes4 constant Withdraw = bytes4(keccak256("BridgeWithdrawFee"));
    bytes4 constant Harvest = bytes4(keccak256("BridgeWithdrawHarvestFee"));
}

contract BridgeWithdrawStrategy is StrategyModule {
    /// ERRORS ///
    error NftSupplyChanged();
    /// @notice Attempted a Wormhole-Executor bridge on a chain where
    /// no executor library was wired in.
    error ExecutorNotConfigured();
    /// @notice Attempted a Wormhole CCTP bridge on a chain where no
    /// source helper library was wired in.
    error WormholeCctpNotConfigured();

    /// STRUCTS ///

    struct Libraries {
        IZapLib zapLib;
        INftZapLib nftZapLib;
        ISwapLib swapLib;
        IFeesLib feesLib;
        ITransferLib transferLib;
        IBridgeLib bridgeLib;
        /// @dev Optional. When zero the typed Wormhole CCTP source path is
        /// disabled; generic BridgeLib entrypoints still work.
        IWormholeCctpLib wormholeCctpLib;
        /// @dev Optional. When zero the Wormhole Executor path is
        /// disabled; the strategy reverts if a caller tries to route
        /// through `*WithExecutor`. All other entrypoints keep working.
        IWormholeExecutorLib wormholeExecutorLib;
    }

    struct BridgeParams {
        address bridgeContract;
        bytes bridgeCalldata;
        address bridgeToken;
        uint256 bridgeAmount;
    }

    /// STORAGE ///

    IZapLib public immutable zapLib;
    INftZapLib public immutable nftZapLib;
    ISwapLib public immutable swapLib;
    IFeesLib public immutable feesLib;
    ITransferLib public immutable transferLib;
    IBridgeLib public immutable bridgeLib;
    /// @dev Zero on chains where Wormhole CCTP is not deployed.
    IWormholeCctpLib public immutable wormholeCctpLib;
    /// @dev Zero on chains where Wormhole Executor is not deployed.
    IWormholeExecutorLib public immutable wormholeExecutorLib;

    address public immutable strategyAddress;

    /// CONSTRUCTOR ///

    constructor(
        SickleFactory factory,
        ConnectorRegistry connectorRegistry,
        Libraries memory libraries
    ) StrategyModule(factory, connectorRegistry) {
        zapLib = libraries.zapLib;
        nftZapLib = libraries.nftZapLib;
        swapLib = libraries.swapLib;
        feesLib = libraries.feesLib;
        transferLib = libraries.transferLib;
        bridgeLib = libraries.bridgeLib;
        wormholeCctpLib = libraries.wormholeCctpLib;
        wormholeExecutorLib = libraries.wormholeExecutorLib;
        strategyAddress = address(this);
    }

    /// WRITE FUNCTIONS ///

    /// @notice Partial unstake from ERC20 farm → bridge
    /// Same params as FarmStrategy.withdraw, with bridge instead of sweep
    function farmDecrease(
        Farm calldata farm,
        WithdrawParams calldata params,
        BridgeParams calldata bridge,
        address[] calldata sweepTokens
    ) external payable {
        Sickle sickle = getSickle(msg.sender);
        _farmWithdraw(sickle, farm, params);
        _bridgeAndSweep(sickle, bridge, sweepTokens);
    }

    /// @notice Harvest + full withdraw from ERC20 farm → bridge
    /// Same params as FarmStrategy.exit, with bridge instead of sweep
    function farmExit(
        Farm calldata farm,
        HarvestParams calldata harvestParams,
        address[] calldata harvestSweepTokens,
        WithdrawParams calldata withdrawParams,
        BridgeParams calldata bridge,
        address[] calldata sweepTokens
    ) external payable {
        Sickle sickle = getSickle(msg.sender);
        _farmHarvest(sickle, farm, harvestParams, harvestSweepTokens);
        _farmWithdraw(sickle, farm, withdrawParams);
        _bridgeAndSweep(sickle, bridge, sweepTokens);
    }

    /// @notice Same as `farmDecrease` but routes the Wormhole send
    /// through the Executor relay framework so destination delivery is
    /// automated. `msg.value` must cover Wormhole core fee + off-chain
    /// quoted Executor fee.
    function farmDecreaseWithExecutor(
        Farm calldata farm,
        WithdrawParams calldata params,
        IWormholeExecutorLib.BridgeArgs calldata bridge,
        IWormholeExecutorLib.ExecutorArgs calldata exec,
        address[] calldata sweepTokens
    ) external payable {
        Sickle sickle = getSickle(msg.sender);
        _farmWithdraw(sickle, farm, params);
        _bridgeAndSweepWithExecutor(sickle, bridge, exec, sweepTokens);
    }

    /// @notice Same as `farmExit` but routes the Wormhole send through
    /// the Executor relay framework. `msg.value` must cover Wormhole
    /// core fee + off-chain quoted Executor fee.
    function farmExitWithExecutor(
        Farm calldata farm,
        HarvestParams calldata harvestParams,
        address[] calldata harvestSweepTokens,
        WithdrawParams calldata withdrawParams,
        IWormholeExecutorLib.BridgeArgs calldata bridge,
        IWormholeExecutorLib.ExecutorArgs calldata exec,
        address[] calldata sweepTokens
    ) external payable {
        Sickle sickle = getSickle(msg.sender);
        _farmHarvest(sickle, farm, harvestParams, harvestSweepTokens);
        _farmWithdraw(sickle, farm, withdrawParams);
        _bridgeAndSweepWithExecutor(sickle, bridge, exec, sweepTokens);
    }

    /// @notice Same as `farmDecrease` but initiates the bridge through
    /// Wormhole Circle Integration with typed params instead of raw calldata.
    /// `msg.value` must equal the Wormhole message fee expected by the
    /// source-chain Circle Integration contract.
    function farmDecreaseWithWormholeCctp(
        Farm calldata farm,
        WithdrawParams calldata params,
        IWormholeCctpLib.TransferArgs calldata bridge,
        address[] calldata sweepTokens
    ) external payable {
        Sickle sickle = getSickle(msg.sender);
        _farmWithdraw(sickle, farm, params);
        _bridgeAndSweepWithWormholeCctp(sickle, bridge, sweepTokens);
    }

    /// @notice Same as `farmExit` but initiates the bridge through Wormhole
    /// Circle Integration with typed params.
    function farmExitWithWormholeCctp(
        Farm calldata farm,
        HarvestParams calldata harvestParams,
        address[] calldata harvestSweepTokens,
        WithdrawParams calldata withdrawParams,
        IWormholeCctpLib.TransferArgs calldata bridge,
        address[] calldata sweepTokens
    ) external payable {
        Sickle sickle = getSickle(msg.sender);
        _farmHarvest(sickle, farm, harvestParams, harvestSweepTokens);
        _farmWithdraw(sickle, farm, withdrawParams);
        _bridgeAndSweepWithWormholeCctp(sickle, bridge, sweepTokens);
    }

    /// @notice Full withdraw NFT from farm → bridge
    /// Same params as NftFarmStrategy.exit, with bridge instead of sweep
    function nftExit(
        NftPosition calldata position,
        NftHarvest calldata harvestParams,
        NftWithdraw calldata withdrawParams,
        BridgeParams calldata bridge,
        address[] calldata sweepTokens
    ) external payable {
        Sickle sickle = getSickle(msg.sender);

        address farmConnector =
            connectorRegistry.connectorOf(position.farm.stakingContract);

        _nftHarvest(sickle, farmConnector, position, harvestParams);
        _withdrawNft(sickle, farmConnector, position, withdrawParams.extraData);
        _nftZapOutAndFees(sickle, withdrawParams);
        _bridgeAndSweep(sickle, bridge, sweepTokens);
    }

    /// @notice Partial decrease from NFT farm → bridge
    /// Same params as NftFarmStrategy.decrease, with bridge instead of sweep
    function nftDecrease(
        NftPosition calldata position,
        NftHarvest calldata harvestParams,
        NftWithdraw calldata withdrawParams,
        bool inPlace,
        BridgeParams calldata bridge,
        address[] calldata sweepTokens
    ) external payable nftSupplyUnchanged(position.nft) {
        Sickle sickle = getSickle(msg.sender);

        address farmConnector =
            connectorRegistry.connectorOf(position.farm.stakingContract);

        if (!inPlace) {
            _nftHarvest(sickle, farmConnector, position, harvestParams);
            _withdrawNft(
                sickle, farmConnector, position, withdrawParams.extraData
            );
        }

        _nftZapOutAndFees(sickle, withdrawParams);

        if (!inPlace) {
            _depositNft(
                sickle, farmConnector, position, withdrawParams.extraData
            );
        }

        _bridgeAndSweep(sickle, bridge, sweepTokens);
    }

    /// @notice Harvest rewards from ERC20 farm → bridge
    /// Same params as FarmStrategy.harvest, with bridge instead of sweep
    function farmHarvest(
        Farm calldata farm,
        HarvestParams calldata harvestParams,
        BridgeParams calldata bridge,
        address[] calldata sweepTokens
    ) external payable {
        Sickle sickle = getSickle(msg.sender);
        _farmHarvestForBridge(sickle, farm, harvestParams);
        _bridgeAndSweep(sickle, bridge, sweepTokens);
    }

    /// @notice Harvest rewards from NFT farm → bridge
    /// Same params as NftFarmStrategy.harvest, with bridge instead of sweep
    function nftHarvest(
        NftPosition calldata position,
        NftHarvest calldata harvestParams,
        BridgeParams calldata bridge,
        address[] calldata sweepTokens
    ) external payable {
        Sickle sickle = getSickle(msg.sender);

        address farmConnector =
            connectorRegistry.connectorOf(position.farm.stakingContract);

        _nftHarvestForBridge(sickle, farmConnector, position, harvestParams);
        _bridgeAndSweep(sickle, bridge, sweepTokens);
    }

    /// INTERNAL ///

    /// @dev ERC20 farm harvest for bridge: claim → swap → fees(bridgeToken)
    function _farmHarvestForBridge(
        Sickle sickle,
        Farm calldata farm,
        HarvestParams calldata h
    ) internal {
        address farmConnector =
            connectorRegistry.connectorOf(farm.stakingContract);

        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);

        targets[0] = farmConnector;
        data[0] = abi.encodeCall(IFarmConnector.claim, (farm, h.extraData));

        targets[1] = address(swapLib);
        data[1] = abi.encodeCall(ISwapLib.swapMultiple, (h.swaps));

        targets[2] = address(feesLib);
        data[2] = abi.encodeCall(
            IFeesLib.chargeFees,
            (strategyAddress, BridgeWithdrawStrategyFees.Harvest, h.tokensOut)
        );

        sickle.multicall(targets, data);
    }

    /// @dev NFT farm harvest for bridge: claim [→ swap] → fees [→ sweep]
    function _nftHarvestForBridge(
        Sickle sickle,
        address farmConnector,
        NftPosition memory position,
        NftHarvest calldata h
    ) internal {
        if (h.swaps.length > 0) {
            address[] memory targets = new address[](3);
            bytes[] memory data = new bytes[](3);

            targets[0] = farmConnector;
            data[0] = abi.encodeCall(
                INftFarmConnector.claim,
                (
                    position,
                    h.harvest.rewardTokens,
                    h.harvest.amount0Max,
                    h.harvest.amount1Max,
                    h.harvest.extraData
                )
            );

            targets[1] = address(swapLib);
            data[1] = abi.encodeCall(ISwapLib.swapMultiple, (h.swaps));

            targets[2] = address(feesLib);
            data[2] = abi.encodeCall(
                IFeesLib.chargeFees,
                (
                    strategyAddress,
                    BridgeWithdrawStrategyFees.Harvest,
                    h.outputTokens
                )
            );

            sickle.multicall(targets, data);
        } else {
            address[] memory targets = new address[](2);
            bytes[] memory data = new bytes[](2);

            targets[0] = farmConnector;
            data[0] = abi.encodeCall(
                INftFarmConnector.claim,
                (
                    position,
                    h.harvest.rewardTokens,
                    h.harvest.amount0Max,
                    h.harvest.amount1Max,
                    h.harvest.extraData
                )
            );

            targets[1] = address(feesLib);
            data[1] = abi.encodeCall(
                IFeesLib.chargeFees,
                (
                    strategyAddress,
                    BridgeWithdrawStrategyFees.Harvest,
                    h.harvest.rewardTokens
                )
            );

            sickle.multicall(targets, data);
        }

        // Sweep harvest leftovers (tokens not being bridged)
        if (h.sweepTokens.length > 0) {
            address[] memory targets = new address[](1);
            bytes[] memory data = new bytes[](1);
            targets[0] = address(transferLib);
            data[0] = abi.encodeCall(
                ITransferLib.transferTokensToUser, (h.sweepTokens)
            );
            sickle.multicall(targets, data);
        }
    }

    /// @dev ERC20 farm harvest: claim → swap → fees → sweep rewards
    function _farmHarvest(
        Sickle sickle,
        Farm calldata farm,
        HarvestParams calldata h,
        address[] calldata harvestSweepTokens
    ) internal {
        address farmConnector =
            connectorRegistry.connectorOf(farm.stakingContract);

        address[] memory targets = new address[](4);
        bytes[] memory data = new bytes[](4);

        targets[0] = farmConnector;
        data[0] = abi.encodeCall(IFarmConnector.claim, (farm, h.extraData));

        targets[1] = address(swapLib);
        data[1] = abi.encodeCall(ISwapLib.swapMultiple, (h.swaps));

        targets[2] = address(feesLib);
        data[2] = abi.encodeCall(
            IFeesLib.chargeFees,
            (strategyAddress, BridgeWithdrawStrategyFees.Harvest, h.tokensOut)
        );

        targets[3] = address(transferLib);
        data[3] = abi.encodeCall(
            ITransferLib.transferTokensToUser, (harvestSweepTokens)
        );

        sickle.multicall(targets, data);
    }

    /// @dev ERC20 farm: connector.withdraw → zapOut [→ fees if swaps
    /// present]
    function _farmWithdraw(
        Sickle sickle,
        Farm calldata farm,
        WithdrawParams calldata params
    ) internal {
        address farmConnector =
            connectorRegistry.connectorOf(farm.stakingContract);

        uint256 len = params.zap.swaps.length > 0 ? 3 : 2;
        address[] memory targets = new address[](len);
        bytes[] memory data = new bytes[](len);

        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            IFarmConnector.withdraw,
            (
                farm,
                params.zap.removeLiquidityParams.lpAmountIn,
                params.extraData
            )
        );

        targets[1] = address(zapLib);
        data[1] = abi.encodeCall(IZapLib.zapOut, (params.zap));

        if (params.zap.swaps.length > 0) {
            targets[2] = address(feesLib);
            data[2] = abi.encodeCall(
                IFeesLib.chargeFees,
                (
                    strategyAddress,
                    BridgeWithdrawStrategyFees.Withdraw,
                    params.tokensOut
                )
            );
        }

        sickle.multicall(targets, data);
    }

    /// @dev NFT farm harvest: claim [→ swap] → fees [→ sweep]
    function _nftHarvest(
        Sickle sickle,
        address farmConnector,
        NftPosition memory position,
        NftHarvest calldata h
    ) internal {
        if (h.swaps.length > 0) {
            address[] memory targets = new address[](3);
            bytes[] memory data = new bytes[](3);

            targets[0] = farmConnector;
            data[0] = abi.encodeCall(
                INftFarmConnector.claim,
                (
                    position,
                    h.harvest.rewardTokens,
                    h.harvest.amount0Max,
                    h.harvest.amount1Max,
                    h.harvest.extraData
                )
            );

            targets[1] = address(swapLib);
            data[1] = abi.encodeCall(ISwapLib.swapMultiple, (h.swaps));

            targets[2] = address(feesLib);
            data[2] = abi.encodeCall(
                IFeesLib.chargeFees,
                (
                    strategyAddress,
                    BridgeWithdrawStrategyFees.Harvest,
                    h.outputTokens
                )
            );

            sickle.multicall(targets, data);
        } else {
            address[] memory targets = new address[](2);
            bytes[] memory data = new bytes[](2);

            targets[0] = farmConnector;
            data[0] = abi.encodeCall(
                INftFarmConnector.claim,
                (
                    position,
                    h.harvest.rewardTokens,
                    h.harvest.amount0Max,
                    h.harvest.amount1Max,
                    h.harvest.extraData
                )
            );

            targets[1] = address(feesLib);
            data[1] = abi.encodeCall(
                IFeesLib.chargeFees,
                (
                    strategyAddress,
                    BridgeWithdrawStrategyFees.Harvest,
                    h.harvest.rewardTokens
                )
            );

            sickle.multicall(targets, data);
        }

        if (h.sweepTokens.length > 0) {
            address[] memory targets = new address[](1);
            bytes[] memory data = new bytes[](1);
            targets[0] = address(transferLib);
            data[0] = abi.encodeCall(
                ITransferLib.transferTokensToUser, (h.sweepTokens)
            );
            sickle.multicall(targets, data);
        }
    }

    /// @dev Withdraw NFT from farm
    function _withdrawNft(
        Sickle sickle,
        address farmConnector,
        NftPosition memory position,
        bytes calldata extraData
    ) internal {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            INftFarmConnector.withdrawNft, (position, extraData)
        );
        sickle.multicall(targets, data);
    }

    /// @dev Deposit existing NFT into farm
    function _depositNft(
        Sickle sickle,
        address farmConnector,
        NftPosition memory position,
        bytes calldata extraData
    ) internal {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            INftFarmConnector.depositExistingNft, (position, extraData)
        );
        sickle.multicall(targets, data);
    }

    /// @dev nftZapOut [+ fee charging if swaps present]
    function _nftZapOutAndFees(
        Sickle sickle,
        NftWithdraw calldata nftWithdraw
    ) internal {
        uint256 len = nftWithdraw.zap.swaps.length > 0 ? 2 : 1;
        address[] memory targets = new address[](len);
        bytes[] memory data = new bytes[](len);

        targets[0] = address(nftZapLib);
        data[0] = abi.encodeCall(INftZapLib.zapOut, (nftWithdraw.zap));

        if (nftWithdraw.zap.swaps.length > 0) {
            targets[1] = address(feesLib);
            data[1] = abi.encodeCall(
                IFeesLib.chargeFees,
                (
                    strategyAddress,
                    BridgeWithdrawStrategyFees.Withdraw,
                    nftWithdraw.tokensOut
                )
            );
        }

        sickle.multicall(targets, data);
    }

    /// @dev Bridge tokens out + sweep leftovers. Payable for relay fees.
    function _bridgeAndSweep(
        Sickle sickle,
        BridgeParams calldata params,
        address[] calldata sweepTokens
    ) internal {
        uint256 len = sweepTokens.length > 0 ? 2 : 1;
        address[] memory targets = new address[](len);
        bytes[] memory data = new bytes[](len);

        targets[0] = address(bridgeLib);
        data[0] = abi.encodeCall(
            IBridgeLib.bridge,
            (
                params.bridgeContract,
                params.bridgeCalldata,
                params.bridgeToken,
                params.bridgeAmount
            )
        );

        if (sweepTokens.length > 0) {
            targets[1] = address(transferLib);
            data[1] = abi.encodeCall(
                ITransferLib.transferTokensToUser, (sweepTokens)
            );
        }

        sickle.multicall{ value: msg.value }(targets, data);
    }

    /// @dev Wormhole-Executor flavor of `_bridgeAndSweep`. Bridges the
    /// Token Bridge publish and the Executor relay-request through a
    /// single delegatecall to `wormholeExecutorLib` so both sub-calls
    /// share the same native balance.
    function _bridgeAndSweepWithExecutor(
        Sickle sickle,
        IWormholeExecutorLib.BridgeArgs calldata bridge,
        IWormholeExecutorLib.ExecutorArgs calldata exec,
        address[] calldata sweepTokens
    ) internal {
        if (address(wormholeExecutorLib) == address(0)) {
            revert ExecutorNotConfigured();
        }

        uint256 len = sweepTokens.length > 0 ? 2 : 1;
        address[] memory targets = new address[](len);
        bytes[] memory data = new bytes[](len);

        targets[0] = address(wormholeExecutorLib);
        data[0] = abi.encodeCall(
            IWormholeExecutorLib.bridgeWithExecutor, (bridge, exec)
        );

        if (sweepTokens.length > 0) {
            targets[1] = address(transferLib);
            data[1] = abi.encodeCall(
                ITransferLib.transferTokensToUser, (sweepTokens)
            );
        }

        sickle.multicall{ value: msg.value }(targets, data);
    }

    /// @dev Wormhole CCTP flavor of `_bridgeAndSweep`.
    function _bridgeAndSweepWithWormholeCctp(
        Sickle sickle,
        IWormholeCctpLib.TransferArgs calldata bridge,
        address[] calldata sweepTokens
    ) internal {
        if (address(wormholeCctpLib) == address(0)) {
            revert WormholeCctpNotConfigured();
        }

        uint256 len = sweepTokens.length > 0 ? 2 : 1;
        address[] memory targets = new address[](len);
        bytes[] memory data = new bytes[](len);

        targets[0] = address(wormholeCctpLib);
        data[0] = abi.encodeCall(
            IWormholeCctpLib.transferTokensWithPayload, (bridge)
        );

        if (sweepTokens.length > 0) {
            targets[1] = address(transferLib);
            data[1] = abi.encodeCall(
                ITransferLib.transferTokensToUser, (sweepTokens)
            );
        }

        sickle.multicall{ value: msg.value }(targets, data);
    }

    /// MODIFIERS ///

    modifier nftSupplyUnchanged(
        INonfungiblePositionManager nft
    ) {
        INftLiquidityConnector liquidityConnector =
            INftLiquidityConnector(connectorRegistry.connectorOf(address(nft)));
        uint256 initialSupply = liquidityConnector.totalSupply(address(nft));
        _;
        if (initialSupply != liquidityConnector.totalSupply(address(nft))) {
            revert NftSupplyChanged();
        }
    }
}
