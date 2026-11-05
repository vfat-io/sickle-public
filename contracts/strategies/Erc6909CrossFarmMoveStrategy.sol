// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    INonfungiblePositionManager
} from "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";

import {
    StrategyModule,
    SickleFactory,
    Sickle
} from "contracts/modules/StrategyModule.sol";
import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { IFarmConnector } from "contracts/interfaces/IFarmConnector.sol";
import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import {
    INftLiquidityConnector
} from "contracts/interfaces/INftLiquidityConnector.sol";
import {
    IErc6909LiquidityConnector
} from "contracts/interfaces/IErc6909LiquidityConnector.sol";
import {
    INftSettingsRegistry
} from "contracts/interfaces/INftSettingsRegistry.sol";
import {
    IPositionSettingsRegistry
} from "contracts/interfaces/IPositionSettingsRegistry.sol";
import { ITransferLib } from "contracts/interfaces/libraries/ITransferLib.sol";
import { ISwapLib } from "contracts/interfaces/libraries/ISwapLib.sol";
import { IFeesLib } from "contracts/interfaces/libraries/IFeesLib.sol";
import { IZapLib } from "contracts/interfaces/libraries/IZapLib.sol";
import { INftZapLib } from "contracts/interfaces/libraries/INftZapLib.sol";
import {
    INftSettingsLib
} from "contracts/interfaces/libraries/INftSettingsLib.sol";
import {
    IPositionSettingsLib
} from "contracts/interfaces/libraries/IPositionSettingsLib.sol";
import { NftSettings } from "contracts/structs/NftSettingsStructs.sol";
import {
    PositionSettings
} from "contracts/structs/PositionSettingsStructs.sol";
import {
    NftPosition,
    NftHarvest,
    SimpleNftHarvest
} from "contracts/structs/NftFarmStrategyStructs.sol";
import { NftZapIn } from "contracts/structs/NftZapStructs.sol";
import { ZapIn } from "contracts/structs/ZapStructs.sol";
import { Farm } from "contracts/structs/FarmStrategyStructs.sol";
import { CrossFarmMoveEvents } from "contracts/events/CrossFarmMoveEvents.sol";
import {
    FarmSource,
    NftFarmSource,
    FarmDeposit,
    MoveToNft,
    MoveToExistingNft,
    MoveToFarm
} from "contracts/structs/CrossFarmMoveStructs.sol";

library Erc6909CrossFarmMoveFees {
    bytes4 constant Harvest = bytes4(keccak256("FarmHarvestFee"));
    bytes4 constant Move = bytes4(keccak256("FarmMoveFee"));
}

contract Erc6909CrossFarmMoveStrategy is StrategyModule, CrossFarmMoveEvents {
    error NoSources();
    error UnexpectedMsgValue();
    error NftSupplyDidntIncrease();
    error NftSupplyChanged();
    error NftLiquidityDidntIncrease();
    error InvalidExistingNftTarget();
    error ExistingNftTargetIsSource();

    struct Libraries {
        ITransferLib transferLib;
        ISwapLib swapLib;
        IFeesLib feesLib;
        IZapLib zapLib;
        INftZapLib nftZapLib;
        INftSettingsLib nftSettingsLib;
        IPositionSettingsLib positionSettingsLib;
    }

    ITransferLib public immutable transferLib;
    ISwapLib public immutable swapLib;
    IFeesLib public immutable feesLib;
    IZapLib public immutable zapLib;
    INftZapLib public immutable nftZapLib;
    INftSettingsLib public immutable nftSettingsLib;
    IPositionSettingsLib public immutable positionSettingsLib;

    INftSettingsRegistry public immutable nftSettingsRegistry;
    IPositionSettingsRegistry public immutable positionSettingsRegistry;

    address public immutable strategyAddress;

    constructor(
        SickleFactory factory,
        ConnectorRegistry connectorRegistry,
        INftSettingsRegistry nftSettingsRegistry_,
        IPositionSettingsRegistry positionSettingsRegistry_,
        Libraries memory libraries
    ) StrategyModule(factory, connectorRegistry) {
        transferLib = libraries.transferLib;
        swapLib = libraries.swapLib;
        feesLib = libraries.feesLib;
        zapLib = libraries.zapLib;
        nftZapLib = libraries.nftZapLib;
        nftSettingsLib = libraries.nftSettingsLib;
        positionSettingsLib = libraries.positionSettingsLib;
        nftSettingsRegistry = nftSettingsRegistry_;
        positionSettingsRegistry = positionSettingsRegistry_;
        strategyAddress = address(this);
    }

    /* External */

    /// @notice Move one or more positions into a single NFT farm position.
    function moveToNft(
        MoveToNft calldata params,
        NftSettings calldata settings,
        address[] calldata sweepTokens
    ) external payable {
        if (params.farmSources.length + params.nftSources.length == 0) {
            revert NoSources();
        }
        if (msg.value > 0 && params.tokensIn.length == 0) {
            revert UnexpectedMsgValue();
        }

        Sickle sickle = getSickle(msg.sender);

        // Transfer additional tokens from user (if any)
        if (params.tokensIn.length > 0) {
            _transferInTokens(sickle, params.tokensIn, params.amountsIn);
        }

        // Exit each ERC20 farm source
        for (uint256 i; i < params.farmSources.length;) {
            _exitFarmSource(sickle, params.farmSources[i]);
            unchecked {
                ++i;
            }
        }

        // Exit each NFT farm source
        for (uint256 i; i < params.nftSources.length;) {
            _exitNftSource(sickle, params.nftSources[i]);
            unchecked {
                ++i;
            }
        }

        // Snapshot supply AFTER source exits (source NFTs may have been
        // burned during zapOut, so snapshotting before would cause false
        // reverts for same-manager moves like Slipstream→Slipstream).
        INftLiquidityConnector liquidityConnector = INftLiquidityConnector(
            connectorRegistry.connectorOf(address(params.deposit.nft))
        );
        uint256 supplyBeforeZapIn =
            liquidityConnector.totalSupply(address(params.deposit.nft));

        // ZapIn to NFT position
        _nftZapIn(sickle, params.deposit.increase.zap);

        if (
            supplyBeforeZapIn
                >= liquidityConnector.totalSupply(address(params.deposit.nft))
        ) {
            revert NftSupplyDidntIncrease();
        }

        // Get new tokenId
        uint256 tokenId = liquidityConnector.getTokenId(
            address(params.deposit.nft), address(sickle)
        );

        // Deposit NFT to farm
        _depositNft(
            sickle,
            NftPosition({
                farm: params.deposit.farm,
                nft: params.deposit.nft,
                tokenId: tokenId
            }),
            params.deposit.increase.extraData
        );

        // Set NFT settings
        _setNftSettings(sickle, params.deposit.nft, tokenId, settings);

        // Sweep remaining tokens
        _sweep(sickle, sweepTokens);

        emit SickleMovedToNft(
            sickle,
            params.deposit.nft,
            tokenId,
            params.deposit.farm.stakingContract,
            params.deposit.farm.poolIndex
        );
    }

    /// @notice Move one or more positions into an existing NFT farm position.
    /// @dev Preserves the target's settings and never mints a destination NFT.
    function moveToExistingNft(
        MoveToExistingNft calldata params,
        address[] calldata sweepTokens
    ) external payable {
        if (params.farmSources.length + params.nftSources.length == 0) {
            revert NoSources();
        }
        if (msg.value > 0 && params.tokensIn.length == 0) {
            revert UnexpectedMsgValue();
        }

        _validateExistingNftTarget(params);

        Sickle sickle = getSickle(msg.sender);

        INftLiquidityConnector liquidityConnector = INftLiquidityConnector(
            connectorRegistry.connectorOf(address(params.target.position.nft))
        );
        (,, uint128 liquidityBefore) = IErc6909LiquidityConnector(
                address(liquidityConnector)
            )
            .positionLiquidityOf(
                address(params.target.position.nft),
                address(sickle),
                params.target.position.tokenId
            );

        // Harvest + unstake the target before any source proceeds enter the
        // Sickle, so the target harvest's fee/sweep cannot touch merge funds.
        // withdrawNft/depositNft dispatch through the target's own farm
        // connector, so a bare (unstaked) target no-ops both and a genuinely
        // staked one round-trips its gauge -- the same trust-`farm` custody
        // model moveToNft/_exitNftSource already use, so the caller's `farm`
        // must match the target's actual custody.
        //
        // Only harvest when the caller asked for it (reward tokens present).
        // An unconditional claim reverts on reward-overlay connectors
        // (Merkl/Metrom/Steer/...) whose claim abi.decodes non-empty extraData,
        // so a bare target with an empty harvest must skip cleanly.
        if (params.target.harvest.harvest.rewardTokens.length > 0) {
            _harvestNft(sickle, params.target.position, params.target.harvest);
        }
        _withdrawNft(
            sickle, params.target.position, params.target.increase.extraData
        );

        // Transfer additional tokens from user (if any)
        if (params.tokensIn.length > 0) {
            _transferInTokens(sickle, params.tokensIn, params.amountsIn);
        }

        // Exit each ERC20 farm source
        for (uint256 i; i < params.farmSources.length;) {
            _exitFarmSource(sickle, params.farmSources[i]);
            unchecked {
                ++i;
            }
        }

        // Exit each NFT farm source
        for (uint256 i; i < params.nftSources.length;) {
            _exitNftSource(sickle, params.nftSources[i]);
            unchecked {
                ++i;
            }
        }

        // Same-manager source NFTs may have been burned. Snapshot after their
        // exits and require the existing-target increase not to mint or burn.
        uint256 supplyBeforeZapIn =
            liquidityConnector.totalSupply(address(params.target.position.nft));

        _nftZapIn(sickle, params.target.increase.zap);

        if (
            supplyBeforeZapIn
                != liquidityConnector.totalSupply(
                    address(params.target.position.nft)
                )
        ) {
            revert NftSupplyChanged();
        }

        (,, uint128 liquidityAfter) = IErc6909LiquidityConnector(
                address(liquidityConnector)
            )
            .positionLiquidityOf(
                address(params.target.position.nft),
                address(sickle),
                params.target.position.tokenId
            );
        if (liquidityAfter <= liquidityBefore) {
            revert NftLiquidityDidntIncrease();
        }

        // Restake the target (no-op for a bare position)
        _depositNft(
            sickle, params.target.position, params.target.increase.extraData
        );

        _sweep(sickle, sweepTokens);

        emit SickleMovedToNft(
            sickle,
            params.target.position.nft,
            params.target.position.tokenId,
            params.target.position.farm.stakingContract,
            params.target.position.farm.poolIndex
        );
    }

    /// @notice Move one or more positions into a single ERC20 farm position.
    function moveToFarm(
        MoveToFarm calldata params,
        PositionSettings calldata settings,
        address[] calldata sweepTokens
    ) external payable {
        if (params.farmSources.length + params.nftSources.length == 0) {
            revert NoSources();
        }
        if (msg.value > 0 && params.tokensIn.length == 0) {
            revert UnexpectedMsgValue();
        }

        Sickle sickle = getSickle(msg.sender);

        // Transfer additional tokens from user (if any)
        if (params.tokensIn.length > 0) {
            _transferInTokens(sickle, params.tokensIn, params.amountsIn);
        }

        // Exit each ERC20 farm source
        for (uint256 i; i < params.farmSources.length;) {
            _exitFarmSource(sickle, params.farmSources[i]);
            unchecked {
                ++i;
            }
        }

        // Exit each NFT farm source
        for (uint256 i; i < params.nftSources.length;) {
            _exitNftSource(sickle, params.nftSources[i]);
            unchecked {
                ++i;
            }
        }

        // ZapIn to ERC20 LP
        _erc20ZapIn(sickle, params.deposit.zap);

        // Deposit to ERC20 farm
        _depositFarm(sickle, params.deposit);

        // Set position settings
        _setPositionSettings(sickle, params.deposit.farm, settings);

        // Sweep remaining tokens
        _sweep(sickle, sweepTokens);

        emit SickleMovedToFarm(
            sickle,
            params.deposit.farm.stakingContract,
            params.deposit.farm.poolIndex
        );
    }

    /* Source exit helpers */

    function _exitFarmSource(
        Sickle sickle,
        FarmSource calldata source
    ) private {
        // Harvest rewards to user
        _harvestFarm(sickle, source);

        // Withdraw LP + zapOut (tokens stay in sickle)
        _withdrawFarm(sickle, source);

        emit SickleMovedFromFarm(
            sickle, source.farm.stakingContract, source.farm.poolIndex
        );
    }

    function _exitNftSource(
        Sickle sickle,
        NftFarmSource calldata source
    ) private {
        // Harvest rewards to user
        _harvestNft(sickle, source.position, source.harvest);

        // Withdraw NFT from farm
        _withdrawNft(sickle, source.position, source.withdraw.extraData);

        // ZapOut + charge move fee (tokens stay in sickle)
        _nftZapOut(sickle, source);

        emit SickleMovedFromNft(
            sickle,
            source.position.nft,
            source.position.tokenId,
            source.position.farm.stakingContract,
            source.position.farm.poolIndex
        );
    }

    /* ERC20 farm building blocks */

    function _harvestFarm(
        Sickle sickle,
        FarmSource calldata source
    ) private {
        address[] memory targets = new address[](4);
        bytes[] memory data = new bytes[](4);

        address farmConnector =
            connectorRegistry.connectorOf(source.farm.stakingContract);
        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            IFarmConnector.claim, (source.farm, source.harvest.extraData)
        );

        targets[1] = address(swapLib);
        data[1] = abi.encodeCall(ISwapLib.swapMultiple, (source.harvest.swaps));

        targets[2] = address(feesLib);
        data[2] = abi.encodeCall(
            IFeesLib.chargeFees,
            (
                strategyAddress,
                Erc6909CrossFarmMoveFees.Harvest,
                source.harvest.tokensOut
            )
        );

        targets[3] = address(transferLib);
        data[3] = abi.encodeCall(
            ITransferLib.transferTokensToUser, (source.harvestSweepTokens)
        );

        sickle.multicall(targets, data);
    }

    function _withdrawFarm(
        Sickle sickle,
        FarmSource calldata source
    ) private {
        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);

        address farmConnector =
            connectorRegistry.connectorOf(source.farm.stakingContract);
        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            IFarmConnector.withdraw,
            (
                source.farm,
                source.withdraw.zap.removeLiquidityParams.lpAmountIn,
                source.withdraw.extraData
            )
        );

        targets[1] = address(zapLib);
        data[1] = abi.encodeCall(IZapLib.zapOut, (source.withdraw.zap));

        targets[2] = address(feesLib);
        data[2] = abi.encodeCall(
            IFeesLib.chargeFees,
            (
                strategyAddress,
                Erc6909CrossFarmMoveFees.Move,
                source.withdraw.tokensOut
            )
        );

        sickle.multicall(targets, data);
    }

    /* NFT farm building blocks */

    function _harvestNft(
        Sickle sickle,
        NftPosition calldata position,
        NftHarvest calldata params
    ) private {
        if (params.swaps.length > 0) {
            _nftClaimAndSwap(sickle, position, params);
        } else {
            _nftClaim(
                sickle,
                position,
                params.harvest,
                Erc6909CrossFarmMoveFees.Harvest
            );
        }

        if (params.sweepTokens.length > 0) {
            _sweep(sickle, params.sweepTokens);
        }
    }

    function _nftClaimAndSwap(
        Sickle sickle,
        NftPosition calldata position,
        NftHarvest calldata params
    ) private {
        address farmConnector =
            connectorRegistry.connectorOf(position.farm.stakingContract);

        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);

        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            INftFarmConnector.claim,
            (
                position,
                params.harvest.rewardTokens,
                params.harvest.amount0Max,
                params.harvest.amount1Max,
                params.harvest.extraData
            )
        );

        targets[1] = address(swapLib);
        data[1] = abi.encodeCall(ISwapLib.swapMultiple, (params.swaps));

        targets[2] = address(feesLib);
        data[2] = abi.encodeCall(
            IFeesLib.chargeFees,
            (
                strategyAddress,
                Erc6909CrossFarmMoveFees.Harvest,
                params.outputTokens
            )
        );
        sickle.multicall(targets, data);
    }

    function _nftClaim(
        Sickle sickle,
        NftPosition calldata position,
        SimpleNftHarvest calldata params,
        bytes4 fee
    ) private {
        address farmConnector =
            connectorRegistry.connectorOf(position.farm.stakingContract);

        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);

        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            INftFarmConnector.claim,
            (
                position,
                params.rewardTokens,
                params.amount0Max,
                params.amount1Max,
                params.extraData
            )
        );

        targets[1] = address(feesLib);
        data[1] = abi.encodeCall(
            IFeesLib.chargeFees, (strategyAddress, fee, params.rewardTokens)
        );

        sickle.multicall(targets, data);
    }

    function _withdrawNft(
        Sickle sickle,
        NftPosition calldata position,
        bytes calldata extraData
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        address farmConnector =
            connectorRegistry.connectorOf(position.farm.stakingContract);

        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            INftFarmConnector.withdrawNft, (position, extraData)
        );

        sickle.multicall(targets, data);
    }

    function _nftZapOut(
        Sickle sickle,
        NftFarmSource calldata source
    ) private {
        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);

        targets[0] = address(nftZapLib);
        data[0] = abi.encodeCall(INftZapLib.zapOut, (source.withdraw.zap));

        targets[1] = address(feesLib);
        data[1] = abi.encodeCall(
            IFeesLib.chargeFees,
            (
                strategyAddress,
                Erc6909CrossFarmMoveFees.Move,
                source.withdraw.tokensOut
            )
        );

        sickle.multicall(targets, data);
    }

    /* Destination building blocks */

    function _transferInTokens(
        Sickle sickle,
        address[] calldata tokensIn,
        uint256[] calldata amountsIn
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(transferLib);
        data[0] = abi.encodeCall(
            ITransferLib.transferTokensFromUser,
            (
                tokensIn,
                amountsIn,
                strategyAddress,
                Erc6909CrossFarmMoveFees.Move
            )
        );

        sickle.multicall{ value: msg.value }(targets, data);
    }

    function _nftZapIn(
        Sickle sickle,
        NftZapIn calldata zap
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(nftZapLib);
        data[0] = abi.encodeCall(INftZapLib.zapIn, (zap));

        sickle.multicall(targets, data);
    }

    function _erc20ZapIn(
        Sickle sickle,
        ZapIn calldata zap
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(zapLib);
        data[0] = abi.encodeCall(IZapLib.zapIn, (zap));

        sickle.multicall(targets, data);
    }

    function _depositNft(
        Sickle sickle,
        NftPosition memory position,
        bytes calldata extraData
    ) private {
        address farmConnector =
            connectorRegistry.connectorOf(position.farm.stakingContract);

        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            INftFarmConnector.depositExistingNft, (position, extraData)
        );

        sickle.multicall(targets, data);
    }

    function _depositFarm(
        Sickle sickle,
        FarmDeposit calldata deposit
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        address farmConnector =
            connectorRegistry.connectorOf(deposit.farm.stakingContract);
        targets[0] = farmConnector;
        data[0] = abi.encodeCall(
            IFarmConnector.deposit,
            (
                deposit.farm,
                deposit.zap.addLiquidityParams.lpToken,
                deposit.extraData
            )
        );

        sickle.multicall(targets, data);
    }

    /* Settings */

    function _setNftSettings(
        Sickle sickle,
        INonfungiblePositionManager nft,
        uint256 tokenId,
        NftSettings calldata settings
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(nftSettingsLib);
        data[0] = abi.encodeCall(
            INftSettingsLib.setNftSettings,
            (nftSettingsRegistry, nft, tokenId, settings)
        );

        sickle.multicall(targets, data);
    }

    function _setPositionSettings(
        Sickle sickle,
        Farm calldata farm,
        PositionSettings calldata settings
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(positionSettingsLib);
        data[0] = abi.encodeCall(
            IPositionSettingsLib.setPositionSettings,
            (positionSettingsRegistry, farm, settings)
        );

        sickle.multicall(targets, data);
    }

    /* Common */

    function _validateExistingNftTarget(
        MoveToExistingNft calldata params
    ) private pure {
        NftPosition calldata position = params.target.position;

        if (
            position.tokenId == 0
                || params.target.increase.zap.addLiquidityParams.tokenId
                    != position.tokenId
                || params.target.increase.zap.addLiquidityParams.nft
                    != position.nft
        ) {
            revert InvalidExistingNftTarget();
        }

        for (uint256 i; i < params.nftSources.length;) {
            NftPosition calldata source = params.nftSources[i].position;
            if (
                source.nft == position.nft && source.tokenId == position.tokenId
            ) {
                revert ExistingNftTargetIsSource();
            }
            unchecked {
                ++i;
            }
        }
    }

    function _sweep(
        Sickle sickle,
        address[] calldata sweepTokens
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(transferLib);
        data[0] =
            abi.encodeCall(ITransferLib.transferTokensToUser, (sweepTokens));

        sickle.multicall(targets, data);
    }
}
