// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    ReentrancyGuard
} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Sickle } from "contracts/Sickle.sol";
import {
    CrossFarmMoveStrategy
} from "contracts/strategies/CrossFarmMoveStrategy.sol";
import { MoveToNft } from "contracts/structs/CrossFarmMoveStructs.sol";
import { NftSettings } from "contracts/structs/NftSettingsStructs.sol";
import { NftAddLiquidity } from "contracts/structs/NftLiquidityStructs.sol";
import { SwapParams } from "contracts/structs/SwapStructs.sol";
import {
    INonfungiblePositionManager
} from "contracts/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import {
    ICLPoolFactory
} from "contracts/interfaces/external/aerodrome/ICLPoolFactory.sol";
import {
    IAeroFactoryRegistry
} from "contracts/interfaces/external/aero/IAeroFactoryRegistry.sol";
import {
    IAeroPool,
    AERO_CL
} from "contracts/interfaces/external/aero/IAeroPool.sol";
import {
    SlipstreamAddLiquidityExtraData
} from "contracts/connectors/velodrome/SlipstreamNftConnector.sol";

/// @notice Atomically migrates independent Sickle positions into
/// separate Aero CL NFTs on this chain. Each leg uses the pinned Move
/// strategy's harvesting, liquidity, fee and settings logic, with the wallet
/// owner intact.
/// @dev Whitelist this contract as a Sickle caller. The Move implementation and
/// its libraries must match the Sickle ABI. No wallet top-ups or native
/// value are accepted; quotes describe existing positions only.
contract AeroMigrationStrategy is ReentrancyGuard {
    struct Migration {
        MoveToNft move;
        NftSettings settings;
        address[] sweepTokens;
    }

    CrossFarmMoveStrategy public immutable moveStrategy;
    INonfungiblePositionManager public immutable aeroNftManager;
    IAeroFactoryRegistry public immutable aeroFactoryRegistry;
    address internal immutable self;

    error InvalidConfiguration();
    error DirectCallRequired();
    error InvalidBatchSize();
    error Expired();
    error InvalidSource();
    error DuplicateSource();
    error WalletInputsNotSupported();
    error InvalidDestination();
    error MissingSweepToken(address token);
    error UnexpectedNftSupply();

    event PositionMigrated(
        address indexed owner,
        address indexed sickle,
        bytes32 indexed sourceKey,
        address pool,
        uint256 tokenId
    );

    constructor(
        CrossFarmMoveStrategy moveStrategy_,
        INonfungiblePositionManager aeroNftManager_,
        IAeroFactoryRegistry aeroFactoryRegistry_
    ) {
        if (
            address(moveStrategy_).code.length == 0
                || address(aeroNftManager_).code.length == 0
                || address(aeroFactoryRegistry_).code.length == 0
        ) revert InvalidConfiguration();
        moveStrategy = moveStrategy_;
        aeroNftManager = aeroNftManager_;
        aeroFactoryRegistry = aeroFactoryRegistry_;
        self = address(this);
    }

    /// @notice Each array item has exactly one source and mints a distinct NFT.
    /// A failed validation, swap, mint or stake reverts the entire batch.
    /// @return tokenIds New Aero NFT IDs, in the same order as the input legs.
    function migrate(
        Migration[] calldata migrations,
        uint256 deadline
    ) external virtual nonReentrant returns (uint256[] memory tokenIds) {
        return _migrate(migrations, deadline);
    }

    function _migrate(
        Migration[] calldata migrations,
        uint256 deadline
    ) internal returns (uint256[] memory tokenIds) {
        if (address(this) != self) revert DirectCallRequired();
        uint256 length = migrations.length;
        if (length == 0) revert InvalidBatchSize();
        if (block.timestamp > deadline) revert Expired();

        Sickle sickle = moveStrategy.getSickle(msg.sender);
        bytes32[] memory sourceKeys = new bytes32[](length);
        // Validate every leg before withdrawing any source.
        for (uint256 i; i < length; ++i) {
            sourceKeys[i] = _validate(migrations[i]);
            for (uint256 j; j < i; ++j) {
                if (sourceKeys[i] == sourceKeys[j]) revert DuplicateSource();
            }
        }

        tokenIds = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            Migration calldata leg = migrations[i];
            uint256 supply = aeroNftManager.totalSupply();
            // CALL would replace msg.sender with this wrapper and resolve the
            // wrong Sickle. Only this fixed, stateless Move implementation is
            // delegated to, and only its typed moveToNft entrypoint is exposed.
            (bool success, bytes memory result) = address(moveStrategy)
                .delegatecall(
                    abi.encodeCall(
                        CrossFarmMoveStrategy.moveToNft,
                        (leg.move, leg.settings, leg.sweepTokens)
                    )
                );
            if (!success) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            if (aeroNftManager.totalSupply() != supply + 1) {
                revert UnexpectedNftSupply();
            }
            // Global enumeration also works after the NFT is staked in a gauge.
            tokenIds[i] = aeroNftManager.tokenByIndex(supply);
            emit PositionMigrated(
                msg.sender,
                address(sickle),
                sourceKeys[i],
                address(leg.settings.pool),
                tokenIds[i]
            );
        }
    }

    function _validate(
        Migration calldata leg
    ) private view returns (bytes32 sourceKey) {
        MoveToNft calldata params = leg.move;
        if (params.farmSources.length + params.nftSources.length != 1) {
            revert InvalidSource();
        }
        if (
            params.tokensIn.length != 0 || params.amountsIn.length != 0
                || params.deposit.increase.tokensIn.length != 0
                || params.deposit.increase.amountsIn.length != 0
        ) {
            revert WalletInputsNotSupported();
        }

        NftAddLiquidity calldata mint =
        params.deposit.increase.zap.addLiquidityParams;
        address pool = address(leg.settings.pool);
        address factory = aeroFactoryRegistry.targetToFactory(pool);
        if (
            params.deposit.nft != aeroNftManager || mint.nft != aeroNftManager
                || mint.tokenId != 0 || leg.settings.poolId != bytes32(0)
                || factory == address(0)
        ) revert InvalidDestination();
        SlipstreamAddLiquidityExtraData memory extra =
            abi.decode(mint.extraData, (SlipstreamAddLiquidityExtraData));
        if (
            IAeroPool(pool).POOL_TYPE() != AERO_CL
                || aeroNftManager.factory() != factory
                || ICLPoolFactory(factory)
                        .getPool(
                            mint.pool.token0,
                            mint.pool.token1,
                            extra.tickSpacing
                        ) != pool || params.deposit.farm.poolIndex != 0
                || (params.deposit.farm.stakingContract
                        != address(aeroNftManager)
                    && aeroFactoryRegistry.gaugeToTarget(
                            params.deposit.farm.stakingContract
                        ) != pool)
        ) revert InvalidDestination();

        _requireSweep(leg.sweepTokens, mint.pool.token0);
        _requireSweep(leg.sweepTokens, mint.pool.token1);
        _requireSwapSweeps(leg.sweepTokens, params.deposit.increase.zap.swaps);
        if (params.farmSources.length == 1) {
            sourceKey = keccak256(
                abi.encode(
                    uint8(0),
                    params.farmSources[0].farm.stakingContract,
                    params.farmSources[0].farm.poolIndex
                )
            );
            _requireSweeps(
                leg.sweepTokens,
                params.farmSources[0].withdraw.zap.removeLiquidityParams.tokens
            );
            _requireSweeps(
                leg.sweepTokens, params.farmSources[0].withdraw.tokensOut
            );
            _requireSwapSweeps(
                leg.sweepTokens, params.farmSources[0].withdraw.zap.swaps
            );
            _requireSweeps(
                leg.sweepTokens, params.farmSources[0].harvest.tokensOut
            );
            _requireSwapSweeps(
                leg.sweepTokens, params.farmSources[0].harvest.swaps
            );
        } else {
            INonfungiblePositionManager nft = params.nftSources[0].position.nft;
            uint256 tokenId = params.nftSources[0].position.tokenId;
            if (
                nft == aeroNftManager
                    || params.nftSources[0].withdraw.zap.removeLiquidityParams
                        .nft != nft
                    || params.nftSources[0].withdraw.zap.removeLiquidityParams
                            .tokenId != tokenId
            ) revert InvalidSource();
            sourceKey = keccak256(abi.encode(uint8(1), nft, tokenId));
            (,, address token0, address token1,,,,,,,,) = nft.positions(tokenId);
            _requireSweep(leg.sweepTokens, token0);
            _requireSweep(leg.sweepTokens, token1);
            _requireSweeps(
                leg.sweepTokens, params.nftSources[0].withdraw.tokensOut
            );
            _requireSwapSweeps(
                leg.sweepTokens, params.nftSources[0].withdraw.zap.swaps
            );
            _requireSweeps(
                leg.sweepTokens,
                params.nftSources[0].harvest.harvest.rewardTokens
            );
            _requireSweeps(
                leg.sweepTokens, params.nftSources[0].harvest.outputTokens
            );
            _requireSwapSweeps(
                leg.sweepTokens, params.nftSources[0].harvest.swaps
            );
        }
    }

    // All declared route tokens must be swept after this leg, including
    // intermediate swap dust and rewards, before the next leg sees balances.
    function _requireSweeps(
        address[] calldata sweepTokens,
        address[] calldata tokens
    ) private pure {
        for (uint256 i; i < tokens.length; ++i) {
            _requireSweep(sweepTokens, tokens[i]);
        }
    }

    function _requireSwapSweeps(
        address[] calldata sweepTokens,
        SwapParams[] calldata swaps
    ) private pure {
        for (uint256 i; i < swaps.length; ++i) {
            _requireSweep(sweepTokens, swaps[i].tokenIn);
            _requireSweep(sweepTokens, swaps[i].tokenOut);
        }
    }

    function _requireSweep(
        address[] calldata tokens,
        address token
    ) private pure {
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == token) return;
        }
        revert MissingSweepToken(token);
    }
}
