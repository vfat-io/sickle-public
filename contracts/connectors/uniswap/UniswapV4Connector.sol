// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import {
    IPositionManager
} from "contracts/interfaces/external/uniswap/v4/IPositionManager.sol";
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
    PositionInfo
} from "contracts/interfaces/external/uniswap/v4/libraries/PositionInfoLibrary.sol";
import {
    Actions
} from "contracts/interfaces/external/uniswap/v4/libraries/Actions.sol";
import {
    Currency
} from "contracts/interfaces/external/uniswap/v4/types/Currency.sol";
import {
    IAllowanceTransfer
} from "contracts/interfaces/external/IAllowanceTransfer.sol";
import {
    Permit2AllowanceLib
} from "contracts/libraries/Permit2AllowanceLib.sol";

import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
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
import {
    FullMath
} from "contracts/interfaces/external/uniswap/v4/libraries/FullMath.sol";
import {
    FixedPoint128
} from "contracts/interfaces/external/uniswap/v4/libraries/FixedPoint128.sol";
import {
    Position
} from "contracts/interfaces/external/uniswap/v4/libraries/Position.sol";

struct UniswapV4MintExtraData {
    uint24 tickSpacing;
    IHooks hooks;
    bytes hookData;
    uint128 liquidity;
}

struct UniswapV4RemoveExtraData {
    Currency currency0;
    Currency currency1;
    bytes hookData;
}

address constant UNISWAP_ETH = 0x0000000000000000000000000000000000000000;

address constant PERMIT_2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

contract UniswapV4Connector is INftLiquidityConnector, INftFarmConnector {
    error InvalidParameters();
    error InvalidDesiredAmount();
    error InvalidTokenOwner();

    IPositionManager public immutable positionManager;
    IStateView public immutable stateView;

    constructor(
        IPositionManager positionManager_,
        IStateView stateView_
    ) {
        positionManager = positionManager_;
        stateView = stateView_;
    }

    function addLiquidity(
        NftAddLiquidity memory addLiquidityParams
    )
        external
        virtual
        override
        checkAmountsForOverflow(
            addLiquidityParams.amount0Desired, addLiquidityParams.amount1Desired
        )
    {
        _addLiquidityInternal(addLiquidityParams);
    }

    function _addLiquidityInternal(
        NftAddLiquidity memory addLiquidityParams
    ) internal virtual {
        if (addLiquidityParams.pool.token0 != UNISWAP_ETH) {
            _approveTokenForPermit2(
                addLiquidityParams.pool.token0,
                addLiquidityParams.amount0Desired
            );
            IAllowanceTransfer(PERMIT_2)
                .approve(
                    addLiquidityParams.pool.token0,
                    address(addLiquidityParams.nft),
                    uint160(addLiquidityParams.amount0Desired),
                    uint48(block.timestamp)
                );
        }
        _approveTokenForPermit2(
            addLiquidityParams.pool.token1, addLiquidityParams.amount1Desired
        );
        IAllowanceTransfer(PERMIT_2)
            .approve(
                addLiquidityParams.pool.token1,
                address(addLiquidityParams.nft),
                uint160(addLiquidityParams.amount1Desired),
                uint48(block.timestamp)
            );

        if (addLiquidityParams.tokenId == 0) {
            _mint(addLiquidityParams);
        } else {
            _increaseLiquidity(addLiquidityParams);
        }

        // Revoke approvals
        if (addLiquidityParams.pool.token0 != UNISWAP_ETH) {
            _revokeTokenForPermit2(addLiquidityParams.pool.token0);
        }
        _revokeTokenForPermit2(addLiquidityParams.pool.token1);
    }

    /// @dev Tokens that fix their Permit2 allowance at infinity (Solady's
    /// `_givePermit2InfiniteAllowance()`) revert on every
    /// `approve(PERMIT_2, x != type(uint256).max)`, so the reset dance below
    /// has to be skipped for them. The allowance is already infinite; only the
    /// `IAllowanceTransfer` leg is still required.
    /// @dev This connector runs under `DELEGATECALL` from the Sickle, so
    /// `address(this)` is the Sickle — the account whose allowance Permit2
    /// spends, and therefore the one to probe.
    function _hasFixedPermit2Allowance(
        address token
    ) internal view returns (bool) {
        return Permit2AllowanceLib.hasFixedAllowance(
            token, address(this), PERMIT_2
        );
    }

    function _approveTokenForPermit2(
        address token,
        uint256 amount
    ) internal {
        if (_hasFixedPermit2Allowance(token)) {
            return;
        }
        SafeTransferLib.safeApprove(token, PERMIT_2, 0);
        SafeTransferLib.safeApprove(token, PERMIT_2, amount);
    }

    function _revokeTokenForPermit2(
        address token
    ) internal {
        if (_hasFixedPermit2Allowance(token)) {
            return;
        }
        SafeTransferLib.safeApprove(token, PERMIT_2, 0);
    }

    function _getCurrentLiquidity(
        NftRemoveLiquidity memory removeLiquidityParams
    ) internal view virtual returns (uint128 currentLiquidity) {
        return IPositionManager(address(removeLiquidityParams.nft))
            .getPositionLiquidity(removeLiquidityParams.tokenId);
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
        uint128 currentLiquidity = _getCurrentLiquidity(removeLiquidityParams);
        if (removeLiquidityParams.liquidity == type(uint128).max) {
            removeLiquidityParams.liquidity = currentLiquidity;
        }

        if (removeLiquidityParams.liquidity == 0) {
            revert InvalidParameters();
        }

        if (removeLiquidityParams.liquidity == currentLiquidity) {
            _burnNft(removeLiquidityParams);
        } else {
            _decreaseLiquidity(removeLiquidityParams);
        }
    }

    function depositExistingNft(
        NftPosition calldata, // position,
        bytes calldata // extraData
    ) external virtual override { }

    function withdrawNft(
        NftPosition calldata, // position,
        bytes calldata // extraData
    ) external virtual override { }

    function claim(
        NftPosition calldata position,
        address[] memory, // rewardTokens
        uint128, // amount0Max
        uint128, // amount1Max
        bytes calldata extraData
    ) external virtual override {
        _collect(
            IPositionManager(address(position.nft)), position.tokenId, extraData
        );
    }

    function fee(
        address, // pool
        uint256 tokenId
    ) external view virtual override returns (uint24) {
        (PoolKey memory poolKey,) =
            positionManager.getPoolAndPositionInfo(tokenId);
        (,,, uint24 lpFee) = stateView.getSlot0(poolKey.toId());
        return lpFee;
    }

    function poolInfo(
        address, // pool
        bytes32 poolId
    ) external view virtual override returns (NftPoolInfo memory) {
        (uint160 sqrtPriceX96, int24 tick_,, uint24 lpFee) =
            stateView.getSlot0(PoolId.wrap(poolId));
        (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) =
            stateView.getFeeGrowthGlobals(PoolId.wrap(poolId));
        uint128 liquidity = stateView.getLiquidity(PoolId.wrap(poolId));
        PoolKey memory poolKey = positionManager.poolKeys(bytes25(poolId));

        return NftPoolInfo({
            token0: Currency.unwrap(poolKey.currency0),
            token1: Currency.unwrap(poolKey.currency1),
            fee: lpFee,
            tickSpacing: uint24(poolKey.tickSpacing),
            sqrtPriceX96: sqrtPriceX96,
            tick: tick_,
            liquidity: liquidity,
            feeGrowthGlobal0X128: feeGrowthGlobal0X128,
            feeGrowthGlobal1X128: feeGrowthGlobal1X128
        });
    }

    function positionLiquidity(
        address, // nftManager
        uint256 tokenId
    )
        public
        view
        virtual
        override
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        PositionInfo positionInfo_ = positionManager.positionInfo(tokenId);
        tickLower = positionInfo_.tickLower();
        tickUpper = positionInfo_.tickUpper();
        liquidity = positionManager.getPositionLiquidity(tokenId);
    }

    function positionPoolKey(
        address, // poolFactory
        address, // nftManager
        uint256 tokenId
    ) external view virtual override returns (NftPoolKey memory) {
        (PoolKey memory poolKey,) =
            positionManager.getPoolAndPositionInfo(tokenId);
        return NftPoolKey({
            poolAddress: address(0), // not used by Uniswap V4
            poolId: PoolId.unwrap(poolKey.toId())
        });
    }

    function getTokenId(
        address, // nftManager
        address owner
    ) external view virtual override returns (uint256 tokenId) {
        tokenId = positionManager.nextTokenId() - 1;
        if (positionManager.ownerOf(tokenId) != owner) {
            revert InvalidTokenOwner();
        }
        return tokenId;
    }

    function totalSupply(
        address // nftManager
    ) external view virtual override returns (uint256) {
        return positionManager.nextTokenId() - 1;
    }

    function _mint(
        NftAddLiquidity memory addLiquidityParams
    ) internal virtual {
        UniswapV4MintExtraData memory extraData =
            abi.decode(addLiquidityParams.extraData, (UniswapV4MintExtraData));

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR),
            uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](3);

        Currency currency0 = Currency.wrap(addLiquidityParams.pool.token0);
        Currency currency1 = Currency.wrap(addLiquidityParams.pool.token1);
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: addLiquidityParams.pool.fee,
            tickSpacing: int24(extraData.tickSpacing),
            hooks: IHooks(extraData.hooks)
        });

        params[0] = abi.encode(
            poolKey,
            addLiquidityParams.tickLower,
            addLiquidityParams.tickUpper,
            extraData.liquidity,
            addLiquidityParams.amount0Desired,
            addLiquidityParams.amount1Desired,
            address(this),
            extraData.hookData
        );
        params[1] = abi.encode(currency0, currency1);
        params[2] = abi.encode(UNISWAP_ETH, address(this));

        uint256 valueToPass =
            currency0.isAddressZero() ? addLiquidityParams.amount0Desired : 0;

        IPositionManager(address(addLiquidityParams.nft))
        .modifyLiquidities{ value: valueToPass }(
            abi.encode(actions, params), block.timestamp
        );
    }

    function _increaseLiquidity(
        NftAddLiquidity memory addLiquidityParams
    ) internal {
        UniswapV4MintExtraData memory extraData =
            abi.decode(addLiquidityParams.extraData, (UniswapV4MintExtraData));

        Currency currency0 = Currency.wrap(addLiquidityParams.pool.token0);
        Currency currency1 = Currency.wrap(addLiquidityParams.pool.token1);

        bytes memory actions;
        bytes[] memory params;

        // Check if position is out of range (only one token needed)
        bool isOutOfRange = addLiquidityParams.amount0Desired == 0
            || addLiquidityParams.amount1Desired == 0;

        if (isOutOfRange) {
            // Out of range: use SETTLE for token being deposited,
            // CLOSE_CURRENCY for the other. CLOSE_CURRENCY handles any fee
            // deltas (positive or
            // negative) which SETTLE_PAIR cannot handle when fees are owed.
            bool needsToken0 = addLiquidityParams.amount0Desired > 0;
            Currency currencyToSettle = needsToken0 ? currency0 : currency1;
            Currency currencyToClose = needsToken0 ? currency1 : currency0;

            // For SETTLE: payerIsUser=true uses Permit2 to pull from caller,
            // payerIsUser=false uses sync()+transfer() from position manager.
            // For non-native currencies, we need payerIsUser=true since tokens
            // are held by the sickle (caller), not the position manager.
            bool payerIsUser = !currencyToSettle.isAddressZero();

            actions = abi.encodePacked(
                uint8(Actions.INCREASE_LIQUIDITY),
                uint8(Actions.SETTLE),
                uint8(Actions.CLOSE_CURRENCY),
                uint8(Actions.SWEEP)
            );
            params = new bytes[](4);
            params[0] = abi.encode(
                addLiquidityParams.tokenId,
                extraData.liquidity,
                addLiquidityParams.amount0Desired,
                addLiquidityParams.amount1Desired,
                extraData.hookData
            );
            params[1] = abi.encode(currencyToSettle, uint256(0), payerIsUser);
            params[2] = abi.encode(currencyToClose);
            params[3] = abi.encode(UNISWAP_ETH, address(this));
        } else {
            actions = abi.encodePacked(
                uint8(Actions.INCREASE_LIQUIDITY),
                uint8(Actions.SETTLE_PAIR),
                uint8(Actions.SWEEP)
            );
            params = new bytes[](3);
            params[0] = abi.encode(
                addLiquidityParams.tokenId,
                extraData.liquidity,
                addLiquidityParams.amount0Desired,
                addLiquidityParams.amount1Desired,
                extraData.hookData
            );
            params[1] = abi.encode(currency0, currency1);
            params[2] = abi.encode(UNISWAP_ETH, address(this));
        }

        uint256 valueToPass =
            currency0.isAddressZero() ? addLiquidityParams.amount0Desired : 0;
        IPositionManager(address(addLiquidityParams.nft))
        .modifyLiquidities{ value: valueToPass }(
            abi.encode(actions, params), block.timestamp
        );
    }

    function _burnNft(
        NftRemoveLiquidity memory removeLiquidityParams
    ) internal {
        UniswapV4RemoveExtraData memory extraData = abi.decode(
            removeLiquidityParams.extraData, (UniswapV4RemoveExtraData)
        );

        bytes memory actions = abi.encodePacked(
            uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            removeLiquidityParams.tokenId,
            uint128(0),
            uint128(0),
            extraData.hookData
        );
        params[1] =
            abi.encode(extraData.currency0, extraData.currency1, address(this));
        IPositionManager(address(removeLiquidityParams.nft))
            .modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _decreaseLiquidity(
        NftRemoveLiquidity memory removeLiquidityParams
    ) internal {
        UniswapV4RemoveExtraData memory extraData = abi.decode(
            removeLiquidityParams.extraData, (UniswapV4RemoveExtraData)
        );

        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            removeLiquidityParams.tokenId,
            removeLiquidityParams.liquidity,
            removeLiquidityParams.amount0Min,
            removeLiquidityParams.amount1Min,
            extraData.hookData
        );

        params[1] =
            abi.encode(extraData.currency0, extraData.currency1, address(this));

        IPositionManager(address(removeLiquidityParams.nft))
            .modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _collect(
        IPositionManager nft,
        uint256 tokenId,
        bytes memory extraData
    ) internal {
        UniswapV4RemoveExtraData memory removeExtraData =
            abi.decode(extraData, (UniswapV4RemoveExtraData));

        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, 0, 0, 0, removeExtraData.hookData);

        params[1] = abi.encode(
            removeExtraData.currency0, removeExtraData.currency1, address(this)
        );

        nft.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function isStaked(
        address, // user
        NftPosition calldata
    ) external view virtual override returns (bool) {
        return false; // Uniswap V4 does not support staking
    }

    function earned(
        address, // user
        NftPosition calldata, // position
        address[] memory rewardTokens
    ) external view virtual override returns (uint256[] memory) {
        // Uniswap V4 does not support token incentives
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

    function earnedFees(
        address, // nftManager
        address, // pool
        uint256 tokenId
    ) external view override returns (uint256 fees0, uint256 fees1) {
        (PoolKey memory poolKey,) =
            positionManager.getPoolAndPositionInfo(tokenId);

        (int24 tickLower, int24 tickUpper, uint128 liquidity) =
            positionLiquidity(address(0), tokenId);

        PoolId poolId = PoolId.wrap(PoolId.unwrap(poolKey.toId()));
        (
            uint256 poolFeeGrowthInside0LastX128,
            uint256 poolFeeGrowthInside1LastX128
        ) = stateView.getFeeGrowthInside(poolId, tickLower, tickUpper);

        bytes32 positionKey = Position.calculatePositionKey(
            address(positionManager), tickLower, tickUpper, bytes32(tokenId)
        );
        (
            ,
            uint256 positionFeeGrowthInside0LastX128,
            uint256 positionFeeGrowthInside1LastX128
        ) = stateView.getPositionInfo(poolId, positionKey);

        unchecked {
            fees0 = FullMath.mulDiv(
                poolFeeGrowthInside0LastX128 - positionFeeGrowthInside0LastX128,
                liquidity,
                FixedPoint128.Q128
            );

            fees1 = FullMath.mulDiv(
                poolFeeGrowthInside1LastX128 - positionFeeGrowthInside1LastX128,
                liquidity,
                FixedPoint128.Q128
            );
        }
    }

    function positionInfo(
        address nftManager,
        uint256 tokenId
    ) external view virtual override returns (NftPositionInfo memory) {
        (int24 tickLower, int24 tickUpper, uint128 liquidity) =
            positionLiquidity(nftManager, tokenId);
        return NftPositionInfo({
            liquidity: liquidity, tickLower: tickLower, tickUpper: tickUpper
        });
    }
}
