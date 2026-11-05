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
    MoveToFarm,
    BatchMove
} from "contracts/structs/CrossFarmMoveStructs.sol";

import { MoveSettingsLib } from "contracts/libraries/MoveSettingsLib.sol";
import {
    MovePosition,
    MoveSourceSettings
} from "contracts/structs/MoveSettingsStructs.sol";

library CrossFarmMoveFees {
    bytes4 constant Harvest = bytes4(keccak256("FarmHarvestFee"));
    bytes4 constant Move = bytes4(keccak256("FarmMoveFee"));
}

contract CrossFarmMoveStrategy is StrategyModule, CrossFarmMoveEvents {
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
        MoveSettingsLib moveSettingsLib;
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

    MoveSettingsLib public immutable moveSettingsLib;
    address public immutable strategyAddress;

    error InvalidBatch();
    error Expired();
    error DirectCallRequired();

    modifier withMoveSettings() {
        _enterMoveSettings();
        _;
        _leaveMoveSettings();
    }

    function _enterMoveSettings() private {
        if (address(moveSettingsLib) != address(0)) {
            // Historical Aero wrappers retain their original Move generation.
            // The new lifecycle is entered directly, preventing double writes.
            if (address(this) != strategyAddress) revert DirectCallRequired();
            moveSettingsLib.enter();
        }
    }

    function _leaveMoveSettings() private {
        if (address(moveSettingsLib) != address(0)) moveSettingsLib.leave();
    }

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
        moveSettingsLib = libraries.moveSettingsLib;
        if (address(libraries.moveSettingsLib) != address(0)) {
            require(
                libraries.moveSettingsLib.factory() == factory
                    && libraries.moveSettingsLib.connectorRegistry()
                        == connectorRegistry
                    && libraries.moveSettingsLib.nftSettingsRegistry()
                    == nftSettingsRegistry_
                    && libraries.moveSettingsLib.positionSettingsRegistry()
                    == positionSettingsRegistry_,
                "Move settings dependency mismatch"
            );
        }
    }

    /* External */

    /// @notice Move one or more positions into a single NFT farm position.
    function moveToNft(
        MoveToNft calldata params,
        NftSettings calldata settings,
        address[] calldata sweepTokens
    ) external payable withMoveSettings returns (uint256 tokenId) {
        if (params.farmSources.length + params.nftSources.length == 0) {
            revert NoSources();
        }
        if (msg.value > 0 && params.tokensIn.length == 0) {
            revert UnexpectedMsgValue();
        }

        Sickle sickle = getSickle(msg.sender);
        MoveSourceSettings[] memory sourceSettings =
            _prepareSettings(sickle, params.farmSources, params.nftSources);

        _exitSources(sickle, params.farmSources, params.nftSources);

        // Transfer additional tokens from user (if any)
        if (params.tokensIn.length > 0) {
            _transferInTokens(sickle, params.tokensIn, params.amountsIn);
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
        tokenId = liquidityConnector.getTokenId(
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

        _applySettings(
            sickle,
            sourceSettings,
            MovePosition(
                address(params.deposit.nft),
                tokenId,
                params.deposit.farm,
                address(settings.pool),
                settings.poolId
            ),
            false
        );

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
    ) external payable withMoveSettings {
        if (params.farmSources.length + params.nftSources.length == 0) {
            revert NoSources();
        }
        if (msg.value > 0 && params.tokensIn.length == 0) {
            revert UnexpectedMsgValue();
        }

        _validateExistingNftTarget(params);

        Sickle sickle = getSickle(msg.sender);
        MoveSourceSettings[] memory sourceSettings =
            _prepareSettings(sickle, params.farmSources, params.nftSources);

        INftLiquidityConnector liquidityConnector = INftLiquidityConnector(
            connectorRegistry.connectorOf(address(params.target.position.nft))
        );
        (,, uint128 liquidityBefore) = liquidityConnector.positionLiquidity(
            address(params.target.position.nft), params.target.position.tokenId
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

        _exitSources(sickle, params.farmSources, params.nftSources);

        // Transfer additional tokens from user (if any)
        if (params.tokensIn.length > 0) {
            _transferInTokens(sickle, params.tokensIn, params.amountsIn);
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

        (,, uint128 liquidityAfter) = liquidityConnector.positionLiquidity(
            address(params.target.position.nft), params.target.position.tokenId
        );
        if (liquidityAfter <= liquidityBefore) {
            revert NftLiquidityDidntIncrease();
        }

        // Restake the target (no-op for a bare position)
        _depositNft(
            sickle, params.target.position, params.target.increase.extraData
        );

        _applySettings(
            sickle,
            sourceSettings,
            MovePosition(
                address(params.target.position.nft),
                params.target.position.tokenId,
                params.target.position.farm,
                address(0),
                bytes32(0)
            ),
            true
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
    ) external payable withMoveSettings {
        if (params.farmSources.length + params.nftSources.length == 0) {
            revert NoSources();
        }
        if (msg.value > 0 && params.tokensIn.length == 0) {
            revert UnexpectedMsgValue();
        }

        Sickle sickle = getSickle(msg.sender);
        MoveSourceSettings[] memory sourceSettings =
            _prepareSettings(sickle, params.farmSources, params.nftSources);

        bool existingTarget;
        if (address(moveSettingsLib) != address(0)) {
            existingTarget =
                moveSettingsLib.hasFarmPosition(sickle, params.deposit.farm);
        }

        _exitSources(sickle, params.farmSources, params.nftSources);

        // Transfer additional tokens from user (if any)
        if (params.tokensIn.length > 0) {
            _transferInTokens(sickle, params.tokensIn, params.amountsIn);
        }

        // ZapIn to ERC20 LP
        _erc20ZapIn(sickle, params.deposit.zap);

        // Deposit to ERC20 farm
        _depositFarm(sickle, params.deposit);

        // Set position settings
        _setPositionSettings(sickle, params.deposit.farm, settings);

        _applySettings(
            sickle,
            sourceSettings,
            MovePosition(
                address(0), 0, params.deposit.farm, address(0), bytes32(0)
            ),
            existingTarget
        );

        // Sweep remaining tokens
        _sweep(sickle, sweepTokens);

        emit SickleMovedToFarm(
            sickle,
            params.deposit.farm.stakingContract,
            params.deposit.farm.poolIndex
        );
    }

    /// @notice Execute independent typed Move legs atomically.
    /// @dev New NFTs execute before farms, then existing NFTs. Batching
    /// excludes native value and wallet top-ups. The API owns the
    /// position-count policy.
    /// @return New NFT IDs followed by zero for each farm/existing-NFT leg.
    function batchMove(
        BatchMove calldata,
        uint256
    ) external returns (uint256[] memory) {
        if (address(this) != strategyAddress) revert DirectCallRequired();
        if (address(moveSettingsLib) == address(0)) revert InvalidBatch();
        // Forward the same typed selector to the deploy-fixed helper. It binds
        // itself to this settings generation and preserves wallet msg.sender.
        // No mutable storage is written in this delegation context.
        (bool success, bytes memory result) =
            address(moveSettingsLib.batchLib()).delegatecall(msg.data);
        assembly {
            if iszero(success) { revert(add(result, 32), mload(result)) }
            return(add(result, 32), mload(result))
        }
    }

    function _prepareSettings(
        Sickle sickle,
        FarmSource[] calldata farms,
        NftFarmSource[] calldata nfts
    ) private view returns (MoveSourceSettings[] memory sources) {
        if (address(moveSettingsLib) == address(0)) {
            return new MoveSourceSettings[](0);
        }
        return moveSettingsLib.prepareSources(sickle, farms, nfts);
    }

    function _applySettings(
        Sickle sickle,
        MoveSourceSettings[] memory sources,
        MovePosition memory destination,
        bool existing
    ) private {
        if (address(moveSettingsLib) == address(0)) return;
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(moveSettingsLib);
        data[0] = abi.encodeCall(
            MoveSettingsLib.applySettings, (sources, destination, existing)
        );
        sickle.multicall(targets, data);
    }

    function _exitSources(
        Sickle sickle,
        FarmSource[] calldata farms,
        NftFarmSource[] calldata nfts
    ) private {
        // Harvest every source before any principal is released. Later reward
        // sweeps must never consume an earlier source's exit proceeds.
        uint256 tokenCount;
        for (uint256 i; i < farms.length; ++i) {
            _harvestFarm(sickle, farms[i]);
            tokenCount += farms[i].withdraw.tokensOut.length;
        }
        for (uint256 i; i < nfts.length; ++i) {
            _harvestNft(sickle, nfts[i].position, nfts[i].harvest);
            tokenCount += nfts[i].withdraw.tokensOut.length;
        }
        for (uint256 i; i < farms.length; ++i) {
            _exitFarmSource(sickle, farms[i]);
        }
        for (uint256 i; i < nfts.length; ++i) {
            _exitNftSource(sickle, nfts[i]);
        }
        address[] memory tokens = new address[](tokenCount);
        uint256 length;
        for (uint256 i; i < farms.length; ++i) {
            length =
                _appendFeeTokens(tokens, length, farms[i].withdraw.tokensOut);
        }
        for (uint256 i; i < nfts.length; ++i) {
            length =
                _appendFeeTokens(tokens, length, nfts[i].withdraw.tokensOut);
        }
        assembly { mstore(tokens, length) }
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(feesLib);
        data[0] = abi.encodeCall(
            IFeesLib.chargeFees,
            (strategyAddress, CrossFarmMoveFees.Move, tokens)
        );
        sickle.multicall(targets, data);
    }

    function _appendFeeTokens(
        address[] memory tokens,
        uint256 length,
        address[] calldata extra
    ) private pure returns (uint256) {
        for (uint256 i; i < extra.length; ++i) {
            bool found;
            for (uint256 j; j < length; ++j) {
                if (tokens[j] == extra[i]) found = true;
            }
            if (!found) tokens[length++] = extra[i];
        }
        return length;
    }

    /* Source exit helpers */

    function _exitFarmSource(
        Sickle sickle,
        FarmSource calldata source
    ) private {
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
        // Withdraw NFT from farm
        _withdrawNft(sickle, source.position, source.withdraw.extraData);

        // ZapOut (tokens stay in Sickle until the shared fee and deposit steps)
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
                CrossFarmMoveFees.Harvest,
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
        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);

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
                sickle, position, params.harvest, CrossFarmMoveFees.Harvest
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
            (strategyAddress, CrossFarmMoveFees.Harvest, params.outputTokens)
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
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(nftZapLib);
        data[0] = abi.encodeCall(INftZapLib.zapOut, (source.withdraw.zap));

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
            (tokensIn, amountsIn, strategyAddress, CrossFarmMoveFees.Move)
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
