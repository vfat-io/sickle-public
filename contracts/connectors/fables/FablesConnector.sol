// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { IHooks } from "contracts/interfaces/external/uniswap/v4/IHooks.sol";
import {
    IStateView
} from "contracts/interfaces/external/uniswap/v4/IStateView.sol";
import {
    PoolId
} from "contracts/interfaces/external/uniswap/v4/types/PoolId.sol";
import {
    PoolKey
} from "contracts/interfaces/external/uniswap/v4/types/PoolKey.sol";
import {
    Currency
} from "contracts/interfaces/external/uniswap/v4/types/Currency.sol";
import {
    LiquidityAmounts
} from "contracts/interfaces/external/uniswap/v4/libraries/LiquidityAmounts.sol";
import {
    TickMath
} from "contracts/interfaces/external/uniswap/v4/libraries/TickMath.sol";
import {
    IFablesLedger,
    IFablesWeightedLedger,
    FablesUserPosition
} from "contracts/interfaces/external/fables/IFablesLedger.sol";
import {
    IFablesPoolRegistry
} from "contracts/interfaces/external/fables/IFablesPoolRegistry.sol";
import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import {
    IErc6909LiquidityConnector
} from "contracts/interfaces/IErc6909LiquidityConnector.sol";
import {
    INftLiquidityConnector,
    NftPoolInfo,
    NftPoolKey,
    NftPositionInfo
} from "contracts/interfaces/INftLiquidityConnector.sol";
import {
    NftAddLiquidity,
    NftRemoveLiquidity
} from "contracts/structs/NftLiquidityStructs.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";

/// @dev Shared extraData for Fables ledger deposit / withdraw / claim / stake.
///      `tickSpacing` and `liquidity` are required for `addLiquidity`.
///      `deadline == 0` means `block.timestamp`. `recipient` is ignored unless
///      it is `address(0)` or the Sickle (`address(this)` under delegatecall);
///      any other address reverts so automators cannot redirect funds.
struct FablesExtraData {
    int24 tickSpacing;
    uint128 liquidity;
    uint256 deadline;
    uint16 maxFeeBps;
    address recipient;
}

address constant FABLES_ETH = address(0);

/// @dev Optional staking envelope. The first five words preserve the existing
///      liquidity/fee payload. Legacy callers may still send FablesExtraData.
///      Select the hook ABI explicitly; a failed call never changes versions.
struct FablesStakeExtraData {
    FablesExtraData ledger;
    uint256 minGaugeWeight;
    bool useGaugeWeight;
}

/// @title FablesConnector
/// @notice Liquidity + farm connector for Fables v4 hooks on Robinhood.
/// @dev Fables LPs mint ERC-6909 range shares on the hook, not PositionManager
///      NFTs. Sickle `tokenId` is the ledger `rangeId`. `nft` / farm target is
///      the hook. `addLiquidity` is delegatecalled from the Sickle.
contract FablesConnector is
    INftLiquidityConnector,
    INftFarmConnector,
    IErc6909LiquidityConnector
{
    error InvalidParameters();
    error InvalidDesiredAmount();
    error InvalidTokenOwner();
    error NotRangeOwner();
    error InvalidRecipient();

    IStateView public immutable stateView;
    IFablesPoolRegistry public immutable poolRegistry;
    address payable private immutable _self;

    /// @dev Last range minted by a Sickle in this tx sequence. Read by
    ///      `getTokenId` after `NftFarmStrategy.deposit`.
    mapping(address owner => uint256 rangeId) public lastRangeId;
    /// @dev Incremented only on tokenId==0 deposits so
    /// `NftFarmStrategy.deposit` sees supply grow while `increase` / harvest
    /// keep it unchanged.
    uint256 public mintCount;

    constructor(
        IStateView stateView_,
        IFablesPoolRegistry poolRegistry_
    ) {
        stateView = stateView_;
        poolRegistry = poolRegistry_;
        _self = payable(address(this));
    }

    /// @dev Fables refunds unspent native `msg.value` to the depositor. Direct
    ///      (non-delegatecall) deposits therefore need a payable fallback on
    ///      this contract. Under Sickle delegatecall the refund hits the
    /// Sickle.
    receive() external payable { }

    function recordMint(
        address owner,
        uint256 rangeId
    ) external {
        if (msg.sender != owner) {
            revert NotRangeOwner();
        }
        lastRangeId[owner] = rangeId;
        unchecked {
            ++mintCount;
        }
    }

    function rangeIdOf(
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(poolId, tickLower, tickUpper)));
    }

    function addLiquidity(
        NftAddLiquidity memory addLiquidityParams
    )
        external
        override
        checkAmountsForOverflow(
            addLiquidityParams.amount0Desired, addLiquidityParams.amount1Desired
        )
    {
        FablesExtraData memory extra = _extra(addLiquidityParams.extraData);
        if (extra.liquidity == 0 || extra.tickSpacing == 0) {
            revert InvalidParameters();
        }

        PoolKey memory key = _poolKey(
            addLiquidityParams.pool.token0,
            addLiquidityParams.pool.token1,
            addLiquidityParams.pool.fee,
            extra.tickSpacing,
            address(addLiquidityParams.nft)
        );

        IFablesLedger ledger = IFablesLedger(address(addLiquidityParams.nft));

        // Fables range shares are fungible, but the strategy tokenId still
        // identifies one exact (pool, lower, upper) range. An increase must
        // therefore use the range encoded by that tokenId; otherwise the
        // deposit would credit a distinct ERC-6909 balance while settings keep
        // tracking the old one.
        if (
            addLiquidityParams.tokenId != 0
                && rangeIdOf(
                        key.toId(),
                        addLiquidityParams.tickLower,
                        addLiquidityParams.tickUpper
                    ) != addLiquidityParams.tokenId
        ) {
            revert InvalidParameters();
        }

        if (addLiquidityParams.pool.token0 != FABLES_ETH) {
            _approve(addLiquidityParams.pool.token0, address(ledger));
        }
        _approve(addLiquidityParams.pool.token1, address(ledger));

        uint256 valueToPass = addLiquidityParams.pool.token0 == FABLES_ETH
            ? addLiquidityParams.amount0Desired
            : 0;

        uint128 liquidity = _boundedLiquidity(
            key.toId(),
            addLiquidityParams.tickLower,
            addLiquidityParams.tickUpper,
            extra.liquidity,
            addLiquidityParams.amount0Desired,
            addLiquidityParams.amount1Desired
        );

        ledger.deposit{ value: valueToPass }(
            key,
            addLiquidityParams.tickLower,
            addLiquidityParams.tickUpper,
            liquidity,
            uint128(addLiquidityParams.amount0Desired),
            uint128(addLiquidityParams.amount1Desired),
            extra.deadline
        );

        if (addLiquidityParams.pool.token0 != FABLES_ETH) {
            _revoke(addLiquidityParams.pool.token0, address(ledger));
        }
        _revoke(addLiquidityParams.pool.token1, address(ledger));

        if (addLiquidityParams.tokenId == 0) {
            FablesConnector(payable(_self))
                .recordMint(
                    address(this),
                    rangeIdOf(
                        key.toId(),
                        addLiquidityParams.tickLower,
                        addLiquidityParams.tickUpper
                    )
                );
        }
    }

    /// @dev A zap can swap through the same pool immediately before adding
    /// liquidity. Size against the post-swap on-chain price and the Sickle's
    /// actual inventory so Fables' strict amount maxima cannot be exceeded.
    /// The off-chain request remains an upper bound.
    function _boundedLiquidity(
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 requestedLiquidity,
        uint256 amount0Max,
        uint256 amount1Max
    ) internal view returns (uint128 liquidity) {
        (uint160 sqrtPriceX96,,,) = stateView.getSlot0(poolId);
        uint128 supportedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Max,
            amount1Max
        );
        liquidity = requestedLiquidity < supportedLiquidity
            ? requestedLiquidity
            : supportedLiquidity;
        if (liquidity == 0) {
            revert InvalidParameters();
        }
    }

    function removeLiquidity(
        NftRemoveLiquidity memory removeLiquidityParams
    )
        external
        override
        checkAmountsForOverflow(
            removeLiquidityParams.amount0Min, removeLiquidityParams.amount1Min
        )
    {
        if (removeLiquidityParams.tokenId == 0) {
            revert InvalidParameters();
        }

        FablesExtraData memory extra = _extra(removeLiquidityParams.extraData);
        _withdraw(
            IFablesLedger(address(removeLiquidityParams.nft)),
            removeLiquidityParams.tokenId,
            removeLiquidityParams.liquidity,
            _boundRecipient(extra.recipient),
            uint128(removeLiquidityParams.amount0Min),
            uint128(removeLiquidityParams.amount1Min),
            extra.deadline
        );
    }

    function _withdraw(
        IFablesLedger ledger,
        uint256 tokenId,
        uint128 liquidity,
        address to,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 deadline
    ) internal {
        (PoolKey memory key, int24 tickLower, int24 tickUpper) =
            _requireRange(ledger, tokenId);

        if (liquidity == type(uint128).max) {
            uint256 shares = ledger.balanceOf(address(this), tokenId);
            if (shares == 0 || shares > type(uint128).max) {
                revert InvalidParameters();
            }
            liquidity = uint128(shares);
        }
        if (liquidity == 0) {
            revert InvalidParameters();
        }

        ledger.withdraw(
            key,
            tickLower,
            tickUpper,
            liquidity,
            to,
            amount0Min,
            amount1Min,
            deadline
        );
    }

    function depositExistingNft(
        NftPosition calldata position,
        bytes calldata extraData
    ) external override {
        // NftFarmStrategy.deposit always calls this after minting. Empty
        // extraData means LP-only. A staking payload opts into assigning
        // future swap fees to voters in exchange for FABLES emissions.
        if (extraData.length == 0) {
            return;
        }
        IFablesLedger ledger = IFablesLedger(address(position.nft));
        (PoolKey memory key, int24 tickLower, int24 tickUpper) =
            _requireRange(ledger, position.tokenId);

        FablesStakeExtraData memory extra = _stakeExtra(extraData);
        uint128 shares = extra.ledger.liquidity;
        if (shares == 0) {
            FablesUserPosition memory pos =
                ledger.userPosition(position.tokenId, address(this));
            uint256 balance = ledger.balanceOf(address(this), position.tokenId);
            if (balance < pos.staked) {
                revert InvalidParameters();
            }
            uint256 unstaked = balance - pos.staked;
            if (unstaked > type(uint128).max) {
                revert InvalidParameters();
            }
            shares = uint128(unstaked);
        }
        if (shares == 0) {
            revert InvalidParameters();
        }
        if (extra.useGaugeWeight) {
            IFablesWeightedLedger(address(ledger))
                .stake(key, tickLower, tickUpper, shares, extra.minGaugeWeight);
        } else {
            ledger.stake(key, tickLower, tickUpper, shares);
        }
    }

    function withdrawNft(
        NftPosition calldata position,
        bytes calldata extraData
    ) external override {
        if (extraData.length == 0) {
            return;
        }
        IFablesLedger ledger = IFablesLedger(address(position.nft));
        (PoolKey memory key, int24 tickLower, int24 tickUpper) =
            _requireRange(ledger, position.tokenId);

        FablesStakeExtraData memory extra = _stakeExtra(extraData);
        uint128 shares = extra.ledger.liquidity;
        if (shares == 0) {
            FablesUserPosition memory pos =
                ledger.userPosition(position.tokenId, address(this));
            shares = pos.staked;
        }
        if (shares == 0) {
            revert InvalidParameters();
        }
        ledger.unstake(key, tickLower, tickUpper, shares);
    }

    function claim(
        NftPosition calldata position,
        address[] memory, // rewardTokens
        uint128, // amount0Max
        uint128, // amount1Max
        bytes calldata extraData
    ) external override {
        IFablesLedger ledger = IFablesLedger(address(position.nft));
        (PoolKey memory key, int24 tickLower, int24 tickUpper) =
            _requireRange(ledger, position.tokenId);

        FablesExtraData memory extra = _extra(extraData);
        ledger.claimFees(
            key,
            tickLower,
            tickUpper,
            _boundRecipient(extra.recipient),
            extra.maxFeeBps
        );
    }

    function fee(
        address hook,
        uint256 tokenId
    ) external view override returns (uint24) {
        if (hook == address(0)) {
            revert InvalidParameters();
        }
        (PoolKey memory key,,) = _requireRange(IFablesLedger(hook), tokenId);
        return IFablesLedger(hook).currentFee(key.toId(), true);
    }

    function poolInfo(
        address, // pool
        bytes32 poolId
    ) external view override returns (NftPoolInfo memory) {
        IFablesPoolRegistry.PoolInfo memory info =
            poolRegistry.poolById(PoolId.wrap(poolId));
        (uint160 sqrtPriceX96, int24 tick_,, uint24 lpFee) =
            stateView.getSlot0(PoolId.wrap(poolId));
        (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) =
            stateView.getFeeGrowthGlobals(PoolId.wrap(poolId));
        uint128 liquidity = stateView.getLiquidity(PoolId.wrap(poolId));

        uint24 fee_ = lpFee;
        if (fee_ == 0) {
            fee_ = IFablesLedger(address(info.key.hooks))
                .currentFee(PoolId.wrap(poolId), true);
        }

        return NftPoolInfo({
            token0: Currency.unwrap(info.key.currency0),
            token1: Currency.unwrap(info.key.currency1),
            fee: fee_,
            tickSpacing: uint24(info.key.tickSpacing),
            sqrtPriceX96: sqrtPriceX96,
            tick: tick_,
            liquidity: liquidity,
            feeGrowthGlobal0X128: feeGrowthGlobal0X128,
            feeGrowthGlobal1X128: feeGrowthGlobal1X128
        });
    }

    function positionLiquidity(
        address nftManager,
        uint256 tokenId
    )
        public
        view
        override
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        return positionLiquidityOf(nftManager, address(this), tokenId);
    }

    /// @dev Owner-aware liquidity. Range shares are fungible; `totalShares` is
    ///      the whole range, not this holder's position.
    function positionLiquidityOf(
        address nftManager,
        address owner,
        uint256 tokenId
    )
        public
        view
        override
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        IFablesLedger ledger = IFablesLedger(nftManager);
        PoolKey memory key;
        (key, tickLower, tickUpper) = _requireRange(ledger, tokenId);
        key;
        uint256 shares = ledger.balanceOf(owner, tokenId);
        if (shares > type(uint128).max) {
            revert InvalidParameters();
        }
        liquidity = uint128(shares);
    }

    function positionPoolKey(
        address, // poolFactory
        address nftManager,
        uint256 tokenId
    ) external view override returns (NftPoolKey memory) {
        (PoolKey memory key,,) =
            _requireRange(IFablesLedger(nftManager), tokenId);
        return NftPoolKey({
            poolAddress: address(0), poolId: PoolId.unwrap(key.toId())
        });
    }

    function getTokenId(
        address, // nftManager
        address owner
    ) external view override returns (uint256 tokenId) {
        tokenId = lastRangeId[owner];
        if (tokenId == 0) {
            revert InvalidTokenOwner();
        }
    }

    function totalSupply(
        address // nftManager
    ) external view override returns (uint256) {
        return mintCount;
    }

    function earnedFees(
        address, // nftManager
        address, // pool
        uint256 // tokenId
    ) external pure override returns (uint256 fees0, uint256 fees1) {
        // Fables fees are per-owner (`userPosition`). This interface has no
        // owner argument; read the hook directly.
        return (0, 0);
    }

    function positionInfo(
        address nftManager,
        uint256 tokenId
    ) external view override returns (NftPositionInfo memory) {
        (int24 tickLower, int24 tickUpper, uint128 liquidity) =
            positionLiquidity(nftManager, tokenId);
        return NftPositionInfo({
            liquidity: liquidity, tickLower: tickLower, tickUpper: tickUpper
        });
    }

    function isStaked(
        address user,
        NftPosition calldata position
    ) external view override returns (bool) {
        FablesUserPosition memory pos = IFablesLedger(address(position.nft))
            .userPosition(position.tokenId, user);
        return pos.staked > 0;
    }

    function earned(
        address, // user
        NftPosition calldata, // position
        address[] memory rewardTokens
    ) external pure override returns (uint256[] memory) {
        return new uint256[](rewardTokens.length);
    }

    modifier checkAmountsForOverflow(
        uint256 amount0,
        uint256 amount1
    ) {
        if (amount0 > type(uint128).max) {
            revert InvalidDesiredAmount();
        }
        if (amount1 > type(uint128).max) {
            revert InvalidDesiredAmount();
        }
        _;
    }

    function _approve(
        address token,
        address spender
    ) internal {
        SafeTransferLib.safeApprove(token, spender, 0);
        SafeTransferLib.safeApprove(token, spender, type(uint256).max);
    }

    function _revoke(
        address token,
        address spender
    ) internal {
        SafeTransferLib.safeApprove(token, spender, 0);
    }

    function _stakeExtra(
        bytes calldata extraData
    ) internal pure returns (FablesStakeExtraData memory extra) {
        if (extraData.length == 160) {
            extra.ledger = abi.decode(extraData, (FablesExtraData));
        } else if (extraData.length == 224) {
            extra = abi.decode(extraData, (FablesStakeExtraData));
        } else {
            revert InvalidParameters();
        }
        if (!extra.useGaugeWeight && extra.minGaugeWeight != 0) {
            revert InvalidParameters();
        }
    }

    function _extra(
        bytes memory extraData
    ) internal view returns (FablesExtraData memory extra) {
        if (extraData.length != 0) {
            extra = abi.decode(extraData, (FablesExtraData));
        }
        if (extra.deadline == 0) {
            extra.deadline = block.timestamp;
        }
    }

    function _boundRecipient(
        address extraRecipient
    ) internal view returns (address) {
        if (extraRecipient == address(0) || extraRecipient == address(this)) {
            return address(this);
        }
        revert InvalidRecipient();
    }

    function _poolKey(
        address token0,
        address token1,
        uint24 fee_,
        int24 tickSpacing,
        address hooks
    ) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee_,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });
    }

    function _requireRange(
        IFablesLedger ledger,
        uint256 tokenId
    )
        internal
        view
        returns (PoolKey memory key, int24 tickLower, int24 tickUpper)
    {
        bool set;
        (key, tickLower, tickUpper, set) = ledger.rangeKey(tokenId);
        if (!set) {
            revert InvalidParameters();
        }
    }
}
