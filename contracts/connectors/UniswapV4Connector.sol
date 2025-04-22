// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPositionManager } from
    "contracts/interfaces/external/uniswap/v4/IPositionManager.sol";
import { IPoolManager } from
    "contracts/interfaces/external/uniswap/v4/IPoolManager.sol";
import { IHooks } from "contracts/interfaces/external/uniswap/v4/IHooks.sol";
import { IStateView } from
    "contracts/interfaces/external/uniswap/v4/IStateView.sol";
import {
    PoolId,
    PoolIdLibrary
} from "contracts/interfaces/external/uniswap/v4/types/PoolId.sol";
import { PoolKey } from
    "contracts/interfaces/external/uniswap/v4/types/PoolKey.sol";
import { PositionInfo } from
    "contracts/interfaces/external/uniswap/v4/libraries/PositionInfoLibrary.sol";
import { Actions } from
    "contracts/interfaces/external/uniswap/v4/libraries/Actions.sol";
import { Currency } from
    "contracts/interfaces/external/uniswap/v4/types/Currency.sol";
import { IAllowanceTransfer } from
    "contracts/interfaces/external/IAllowanceTransfer.sol";

import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import {
    INftLiquidityConnector,
    NftPoolInfo,
    NftPositionInfo,
    NftPoolKey
} from "contracts/interfaces/INftLiquidityConnector.sol";
import { SwapParams } from "contracts/structs/LiquidityStructs.sol";
import {
    NftAddLiquidity,
    NftRemoveLiquidity,
    Pool
} from "contracts/structs/NftLiquidityStructs.sol";
import { Farm } from "contracts/structs/FarmStrategyStructs.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";
import { StateLibrary } from
    "contracts/interfaces/external/uniswap/v4/libraries/StateLibrary.sol";
import { TickMath } from
    "contracts/interfaces/external/uniswap/v4/libraries/TickMath.sol";

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
    error NotImplemented();

    IPositionManager public immutable positionManager;
    IStateView public immutable stateView;

    constructor(IPositionManager positionManager_, IStateView stateView_) {
        positionManager = positionManager_;
        stateView = stateView_;
    }

    function addLiquidity(
        NftAddLiquidity memory addLiquidityParams
    )
        external
        payable
        override
        checkAmountsForOverflow(
            addLiquidityParams.amount0Desired,
            addLiquidityParams.amount1Desired
        )
    {
        if (addLiquidityParams.pool.token0 != UNISWAP_ETH) {
            IERC20(addLiquidityParams.pool.token0).approve(
                address(PERMIT_2), addLiquidityParams.amount0Desired
            );
            IAllowanceTransfer(PERMIT_2).approve(
                addLiquidityParams.pool.token0,
                address(addLiquidityParams.nft),
                uint160(addLiquidityParams.amount0Desired),
                uint48(block.timestamp)
            );
        }
        IERC20(addLiquidityParams.pool.token1).approve(
            address(PERMIT_2), addLiquidityParams.amount1Desired
        );
        IAllowanceTransfer(PERMIT_2).approve(
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
            IERC20(addLiquidityParams.pool.token0).approve(address(PERMIT_2), 0);
        }
        IERC20(addLiquidityParams.pool.token1).approve(address(PERMIT_2), 0);
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
            removeLiquidityParams.amount0Min,
            removeLiquidityParams.amount1Min
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

    function swapExactTokensForTokens(
        SwapParams memory
    ) external payable virtual override {
        revert NotImplemented();
    }

    function depositExistingNft(
        NftPosition calldata, // position,
        bytes calldata // extraData
    ) external payable virtual override { }

    function withdrawNft(
        NftPosition calldata, // position,
        bytes calldata // extraData
    ) external payable virtual override { }

    function claim(
        NftPosition calldata position,
        address[] memory, // rewardTokens
        uint128, // amount0Max
        uint128, // amount1Max
        bytes calldata extraData
    ) external payable virtual override {
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

    function positionInfo(
        address, // nftManager
        uint256 tokenId
    ) external view virtual override returns (NftPositionInfo memory) {
        PositionInfo positionInfo_ = positionManager.positionInfo(tokenId);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        return NftPositionInfo({
            liquidity: liquidity,
            tickLower: positionInfo_.tickLower(),
            tickUpper: positionInfo_.tickUpper()
        });
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

    function feeGrowthOutside(
        address, // pool
        bytes32 poolId,
        int24 tick
    )
        external
        view
        virtual
        override
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128)
    {
        (,, feeGrowthOutside0X128, feeGrowthOutside1X128) =
            stateView.getTickInfo(PoolId.wrap(poolId), tick);
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

        IPositionManager(address(addLiquidityParams.nft)).modifyLiquidities{
            value: valueToPass
        }(abi.encode(actions, params), block.timestamp);
    }

    function _increaseLiquidity(
        NftAddLiquidity memory addLiquidityParams
    ) internal {
        UniswapV4MintExtraData memory extraData =
            abi.decode(addLiquidityParams.extraData, (UniswapV4MintExtraData));

        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY),
            uint8(Actions.SETTLE_PAIR),
            uint8(Actions.SWEEP)
        );

        bytes[] memory params = new bytes[](3);

        params[0] = abi.encode(
            addLiquidityParams.tokenId,
            extraData.liquidity,
            addLiquidityParams.amount0Desired,
            addLiquidityParams.amount1Desired,
            extraData.hookData
        );

        params[1] = abi.encode(
            Currency.wrap(addLiquidityParams.pool.token0),
            Currency.wrap(addLiquidityParams.pool.token1)
        );

        params[2] = abi.encode(UNISWAP_ETH, address(this));

        uint256 valueToPass = Currency.wrap(addLiquidityParams.pool.token0)
            .isAddressZero() ? addLiquidityParams.amount0Desired : 0;
        IPositionManager(address(addLiquidityParams.nft)).modifyLiquidities{
            value: valueToPass
        }(abi.encode(actions, params), block.timestamp);
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
        IPositionManager(address(removeLiquidityParams.nft)).modifyLiquidities(
            abi.encode(actions, params), block.timestamp
        );
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

        IPositionManager(address(removeLiquidityParams.nft)).modifyLiquidities(
            abi.encode(actions, params), block.timestamp
        );
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
        NftPosition calldata,
        address[] memory rewardTokens
    ) external view virtual override returns (uint256[] memory) {
        // Uniswap V4 does not support token incentives
        return new uint256[](rewardTokens.length);
    }

    modifier checkAmountsForOverflow(uint256 amount0, uint256 amount1) {
        if (amount0 > type(uint128).max) {
            revert InvalidDesiredAmount();
        }
        if (amount1 > type(uint128).max) {
            revert InvalidDesiredAmount();
        }
        _;
    }
}
