// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import {
    ICLPositionManager
} from
    "contracts/interfaces/external/pancake/infinity/ICLPositionManager.sol";
import {
    ICLPoolManager,
    CLPositionInfo,
    CLTickInfo
} from "contracts/interfaces/external/pancake/infinity/ICLPoolManager.sol";
import {
    PancakePoolKey,
    PancakePoolKeyLibrary
} from "contracts/interfaces/external/pancake/infinity/PancakePoolKey.sol";
import { IHooks } from "contracts/interfaces/external/uniswap/v4/IHooks.sol";
import {
    PoolId
} from "contracts/interfaces/external/uniswap/v4/types/PoolId.sol";
import {
    PositionInfo
} from
    "contracts/interfaces/external/uniswap/v4/libraries/PositionInfoLibrary.sol";
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

struct PancakeInfinityMintExtraData {
    ICLPoolManager poolManager;
    IHooks hooks;
    bytes32 parameters;
    bytes hookData;
    uint128 liquidity;
}

struct PancakeInfinityRemoveExtraData {
    Currency currency0;
    Currency currency1;
    bytes hookData;
}

address constant PANCAKE_ETH = 0x0000000000000000000000000000000000000000;

contract PancakeInfinityConnector is INftLiquidityConnector, INftFarmConnector {
    using PancakePoolKeyLibrary for PancakePoolKey;

    error InvalidParameters();
    error InvalidDesiredAmount();
    error InvalidTokenOwner();

    ICLPositionManager public immutable positionManager;
    ICLPoolManager public immutable poolManager;
    address public immutable permit2;

    constructor(
        ICLPositionManager positionManager_,
        ICLPoolManager poolManager_,
        address permit2_
    ) {
        positionManager = positionManager_;
        poolManager = poolManager_;
        permit2 = permit2_;
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
        if (addLiquidityParams.pool.token0 != PANCAKE_ETH) {
            _approveTokenForPermit2(
                addLiquidityParams.pool.token0,
                addLiquidityParams.amount0Desired
            );
            IAllowanceTransfer(permit2).approve(
                addLiquidityParams.pool.token0,
                address(addLiquidityParams.nft),
                uint160(addLiquidityParams.amount0Desired),
                uint48(block.timestamp)
            );
        }
        _approveTokenForPermit2(
            addLiquidityParams.pool.token1, addLiquidityParams.amount1Desired
        );
        IAllowanceTransfer(permit2).approve(
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
        if (addLiquidityParams.pool.token0 != PANCAKE_ETH) {
            _revokeTokenForPermit2(addLiquidityParams.pool.token0);
        }
        _revokeTokenForPermit2(addLiquidityParams.pool.token1);
    }

    /// @dev Tokens that fix their Permit2 allowance at infinity (Solady's
    /// `_givePermit2InfiniteAllowance()`) revert on every
    /// `approve(permit2, x != type(uint256).max)`, so the reset dance below
    /// has to be skipped for them. The allowance is already infinite; only the
    /// `IAllowanceTransfer` leg is still required.
    /// @dev This connector runs under `DELEGATECALL` from the Sickle, so
    /// `address(this)` is the Sickle — the account whose allowance Permit2
    /// spends, and therefore the one to probe.
    function _hasFixedPermit2Allowance(
        address token
    ) internal view returns (bool) {
        return Permit2AllowanceLib.hasFixedAllowance(
            token, address(this), permit2
        );
    }

    function _approveTokenForPermit2(
        address token,
        uint256 amount
    ) internal {
        if (_hasFixedPermit2Allowance(token)) {
            return;
        }
        SafeTransferLib.safeApprove(token, permit2, 0);
        SafeTransferLib.safeApprove(token, permit2, amount);
    }

    function _revokeTokenForPermit2(
        address token
    ) internal {
        if (_hasFixedPermit2Allowance(token)) {
            return;
        }
        SafeTransferLib.safeApprove(token, permit2, 0);
    }

    function _getCurrentLiquidity(
        NftRemoveLiquidity memory removeLiquidityParams
    ) internal view virtual returns (uint128 currentLiquidity) {
        return ICLPositionManager(address(removeLiquidityParams.nft))
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
            ICLPositionManager(address(position.nft)),
            position.tokenId,
            extraData
        );
    }

    function fee(
        address, // pool
        uint256 tokenId
    ) external view virtual override returns (uint24) {
        (PancakePoolKey memory poolKey,) =
            positionManager.getPoolAndPositionInfo(tokenId);
        PoolId poolId = _toPoolId(poolKey);
        (,,, uint24 lpFee) = poolManager.getSlot0(poolId);
        return lpFee;
    }

    function poolInfo(
        address, // pool
        bytes32 poolId
    ) external view virtual override returns (NftPoolInfo memory) {
        (uint160 sqrtPriceX96, int24 tick_,, uint24 lpFee) =
            poolManager.getSlot0(PoolId.wrap(poolId));
        (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) =
            poolManager.getFeeGrowthGlobals(PoolId.wrap(poolId));
        uint128 liquidity = poolManager.getLiquidity(PoolId.wrap(poolId));

        // Get pool key from position manager to extract tick spacing
        PancakePoolKey memory poolKey = positionManager.poolKeys(bytes25(poolId));

        return NftPoolInfo({
            token0: Currency.unwrap(poolKey.currency0),
            token1: Currency.unwrap(poolKey.currency1),
            fee: lpFee,
            tickSpacing: uint24(poolKey.getTickSpacing()),
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
        (PancakePoolKey memory poolKey,) =
            positionManager.getPoolAndPositionInfo(tokenId);
        return NftPoolKey({
            poolAddress: address(0), // Not used by PancakeSwap Infinity
            poolId: PoolId.unwrap(_toPoolId(poolKey))
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
        PancakeInfinityMintExtraData memory extraData = abi.decode(
            addLiquidityParams.extraData, (PancakeInfinityMintExtraData)
        );

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR),
            uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](3);

        Currency currency0 = Currency.wrap(addLiquidityParams.pool.token0);
        Currency currency1 = Currency.wrap(addLiquidityParams.pool.token1);

        PancakePoolKey memory poolKey = PancakePoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: extraData.hooks,
            poolManager: extraData.poolManager,
            fee: addLiquidityParams.pool.fee,
            parameters: extraData.parameters
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
        params[2] = abi.encode(PANCAKE_ETH, address(this));

        uint256 valueToPass =
            currency0.isAddressZero() ? addLiquidityParams.amount0Desired : 0;

        ICLPositionManager(address(addLiquidityParams.nft)).modifyLiquidities{
            value: valueToPass
        }(abi.encode(actions, params), block.timestamp);
    }

    function _increaseLiquidity(
        NftAddLiquidity memory addLiquidityParams
    ) internal {
        PancakeInfinityMintExtraData memory extraData = abi.decode(
            addLiquidityParams.extraData, (PancakeInfinityMintExtraData)
        );

        Currency currency0 = Currency.wrap(addLiquidityParams.pool.token0);
        Currency currency1 = Currency.wrap(addLiquidityParams.pool.token1);

        bytes memory actions;
        bytes[] memory params;

        // Check if this is an out-of-range position (only one token needed)
        bool isOutOfRange = addLiquidityParams.amount0Desired == 0
            || addLiquidityParams.amount1Desired == 0;

        if (isOutOfRange) {
            bool needsToken0 = addLiquidityParams.amount0Desired > 0;
            Currency currencyToSettle = needsToken0 ? currency0 : currency1;
            Currency currencyToClose = needsToken0 ? currency1 : currency0;

            // For ERC20 tokens, we need Permit2 to pull from the sickle (payerIsUser = true)
            // For native ETH, we send via msg.value (payerIsUser = false)
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
            params[3] = abi.encode(PANCAKE_ETH, address(this));
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
            params[2] = abi.encode(PANCAKE_ETH, address(this));
        }

        uint256 valueToPass =
            currency0.isAddressZero() ? addLiquidityParams.amount0Desired : 0;
        ICLPositionManager(address(addLiquidityParams.nft)).modifyLiquidities{
            value: valueToPass
        }(abi.encode(actions, params), block.timestamp);
    }

    function _burnNft(
        NftRemoveLiquidity memory removeLiquidityParams
    ) internal {
        PancakeInfinityRemoveExtraData memory extraData = abi.decode(
            removeLiquidityParams.extraData, (PancakeInfinityRemoveExtraData)
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
        ICLPositionManager(address(removeLiquidityParams.nft))
            .modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _decreaseLiquidity(
        NftRemoveLiquidity memory removeLiquidityParams
    ) internal {
        PancakeInfinityRemoveExtraData memory extraData = abi.decode(
            removeLiquidityParams.extraData, (PancakeInfinityRemoveExtraData)
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

        ICLPositionManager(address(removeLiquidityParams.nft))
            .modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _collect(
        ICLPositionManager nft,
        uint256 tokenId,
        bytes memory extraData
    ) internal {
        PancakeInfinityRemoveExtraData memory removeExtraData =
            abi.decode(extraData, (PancakeInfinityRemoveExtraData));

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
        return false; // PancakeSwap Infinity does not support staking
    }

    function earned(
        address, // user
        NftPosition calldata, // position
        address[] memory rewardTokens
    ) external view virtual override returns (uint256[] memory) {
        // PancakeSwap Infinity does not support token incentives
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

    function earnedFees(
        address, // nftManager
        address, // pool
        uint256 tokenId
    ) external view override returns (uint256 fees0, uint256 fees1) {
        (fees0, fees1) = _calculateEarnedFees(tokenId);
    }

    function _calculateEarnedFees(
        uint256 tokenId
    ) internal view returns (uint256 fees0, uint256 fees1) {
        (PancakePoolKey memory poolKey,) =
            positionManager.getPoolAndPositionInfo(tokenId);

        (int24 tickLower, int24 tickUpper, uint128 liquidity) =
            positionLiquidity(address(0), tokenId);

        PoolId poolId = _toPoolId(poolKey);

        CLPositionInfo memory posInfo = poolManager.getPosition(
            poolId,
            address(positionManager),
            tickLower,
            tickUpper,
            bytes32(tokenId)
        );

        (
            uint256 feeGrowthInside0X128,
            uint256 feeGrowthInside1X128
        ) = _getFeeGrowthInside(poolId, tickLower, tickUpper);

        unchecked {
            fees0 = FullMath.mulDiv(
                feeGrowthInside0X128 - posInfo.feeGrowthInside0LastX128,
                liquidity,
                FixedPoint128.Q128
            );

            fees1 = FullMath.mulDiv(
                feeGrowthInside1X128 - posInfo.feeGrowthInside1LastX128,
                liquidity,
                FixedPoint128.Q128
            );
        }
    }

    /// @dev PancakeSwap Infinity CLPoolManager does not expose getFeeGrowthInside,
    /// so we reconstruct it from the per-tick feeGrowthOutside snapshots and the
    /// pool's fee growth globals, following the v3/v4 convention (unchecked wrap).
    function _getFeeGrowthInside(
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper
    )
        internal
        view
        returns (
            uint256 feeGrowthInside0X128,
            uint256 feeGrowthInside1X128
        )
    {
        CLTickInfo memory lower = poolManager.getPoolTickInfo(poolId, tickLower);
        CLTickInfo memory upper = poolManager.getPoolTickInfo(poolId, tickUpper);
        (, int24 tickCurrent,,) = poolManager.getSlot0(poolId);
        (
            uint256 feeGrowthGlobal0X128,
            uint256 feeGrowthGlobal1X128
        ) = poolManager.getFeeGrowthGlobals(poolId);

        unchecked {
            uint256 feeGrowthBelow0X128;
            uint256 feeGrowthBelow1X128;
            if (tickCurrent >= tickLower) {
                feeGrowthBelow0X128 = lower.feeGrowthOutside0X128;
                feeGrowthBelow1X128 = lower.feeGrowthOutside1X128;
            } else {
                feeGrowthBelow0X128 =
                    feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;
                feeGrowthBelow1X128 =
                    feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;
            }

            uint256 feeGrowthAbove0X128;
            uint256 feeGrowthAbove1X128;
            if (tickCurrent < tickUpper) {
                feeGrowthAbove0X128 = upper.feeGrowthOutside0X128;
                feeGrowthAbove1X128 = upper.feeGrowthOutside1X128;
            } else {
                feeGrowthAbove0X128 =
                    feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;
                feeGrowthAbove1X128 =
                    feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128;
            }

            feeGrowthInside0X128 =
                feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
            feeGrowthInside1X128 =
                feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
        }
    }

    function positionInfo(
        address nftManager,
        uint256 tokenId
    ) external view virtual override returns (NftPositionInfo memory) {
        (int24 tickLower, int24 tickUpper, uint128 liquidity) =
            positionLiquidity(nftManager, tokenId);
        return NftPositionInfo({
            liquidity: liquidity,
            tickLower: tickLower,
            tickUpper: tickUpper
        });
    }

    /// @notice Convert PancakePoolKey to PoolId
    /// @dev PoolId is keccak256 hash of the encoded pool key
    function _toPoolId(
        PancakePoolKey memory key
    ) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(key)));
    }
}
