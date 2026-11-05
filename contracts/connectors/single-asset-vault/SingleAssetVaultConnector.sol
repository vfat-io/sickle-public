// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import {
    ILiquidityConnector
} from "contracts/interfaces/ILiquidityConnector.sol";
import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import {
    AddLiquidityParams,
    RemoveLiquidityParams
} from "contracts/structs/LiquidityStructs.sol";

/// @dev Exact static ABI tuples; lengths are checked before decoding.
struct SingleAssetVaultDepositExtraData {
    uint256 minShares;
}

struct SingleAssetVaultFarmExtraData {
    address asset;
}

/// @notice Synchronous one-asset vault execution through FarmStrategy/ZapLib.
/// @dev Delegated mutators hold assets and shares in address(this), the Sickle;
/// msg.sender remains the strategy. No Sickle storage is read or written.
/// Protocol implementations authenticate vaults and restrict supported assets.
/// There is no external staking/reward leg: farm mutators only validate input.
abstract contract SingleAssetVaultConnector is
    ILiquidityConnector,
    IFarmConnector
{
    error InvalidVault();
    error InvalidAsset();
    error InvalidRouter();
    error InvalidArrayLength();
    error InvalidExtraData();
    error InvalidAmount();
    error InvalidPoolIndex();
    error InsufficientShares();
    error InsufficientAssets();
    error UnsupportedTokenBehavior();
    error UnsupportedPairPrice();
    error UnsupportedRewards();
    error DelegateCallRequired();

    address private immutable self = address(this);

    modifier onlyDelegateCall() {
        if (address(this) == self) revert DelegateCallRequired();
        _;
    }

    /// @notice Registry probe. Unknown/disabled vaults answer false.
    function isVault(
        address vault
    ) public view virtual returns (bool);

    /// @dev Must authenticate provenance and asset policy before returning.
    function _asset(
        address vault
    ) internal view virtual returns (address);

    /// @dev Recorded backing, not idle liquidity or a projected rate.
    function _recordedAssets(
        address vault
    ) internal view virtual returns (uint256);

    function addLiquidity(
        AddLiquidityParams memory p
    ) external override onlyDelegateCall {
        address asset = _asset(p.lpToken);
        if (p.router != p.lpToken) revert InvalidRouter();
        if (
            p.tokens.length != 1 || p.desiredAmounts.length != 1
                || p.minAmounts.length != 1
        ) revert InvalidArrayLength();
        if (p.tokens[0] != asset) revert InvalidAsset();
        if (p.extraData.length != 32) revert InvalidExtraData();
        SingleAssetVaultDepositExtraData memory extra =
            abi.decode(p.extraData, (SingleAssetVaultDepositExtraData));
        uint256 amount = p.desiredAmounts[0];
        uint256 assetsBefore = IERC20(asset).balanceOf(address(this));
        if (amount == 0 || amount == type(uint256).max || amount > assetsBefore)
        {
            revert InvalidAmount();
        }
        // minAmounts is in asset units. It never means minimum shares.
        if (amount < p.minAmounts[0]) revert InsufficientAssets();
        uint256 sharesBefore = IERC20(p.lpToken).balanceOf(address(this));

        SafeTransferLib.safeApprove(asset, p.lpToken, 0);
        SafeTransferLib.safeApprove(asset, p.lpToken, amount);
        uint256 minted = _deposit(p.lpToken, amount);
        SafeTransferLib.safeApprove(asset, p.lpToken, 0);

        uint256 sharesAfter = IERC20(p.lpToken).balanceOf(address(this));
        if (
            IERC20(asset).balanceOf(address(this)) != assetsBefore - amount
                || sharesAfter < sharesBefore
                || sharesAfter - sharesBefore != minted
        ) {
            revert UnsupportedTokenBehavior();
        }
        if (minted == 0 || minted < extra.minShares) {
            revert InsufficientShares();
        }
    }

    function removeLiquidity(
        RemoveLiquidityParams memory p
    ) external override onlyDelegateCall {
        address asset = _asset(p.lpToken);
        if (p.router != p.lpToken) revert InvalidRouter();
        if (p.tokens.length != 1 || p.minAmountsOut.length != 1) {
            revert InvalidArrayLength();
        }
        if (p.tokens[0] != asset) revert InvalidAsset();
        if (p.extraData.length != 0) revert InvalidExtraData();
        uint256 sharesBefore = IERC20(p.lpToken).balanceOf(address(this));
        _checkShares(p.lpAmountIn, sharesBefore);
        uint256 assetsBefore = IERC20(asset).balanceOf(address(this));

        // ZapLib grants a share allowance. Self-redemption needs none; clear
        // it before the call, including any seeded stale approval.
        SafeTransferLib.safeApprove(p.lpToken, p.lpToken, 0);
        uint256 returned = _redeem(p.lpToken, p.lpAmountIn);
        uint256 assetsAfter = IERC20(asset).balanceOf(address(this));
        if (
            IERC20(p.lpToken).balanceOf(address(this))
                    != sharesBefore - p.lpAmountIn || assetsAfter < assetsBefore
                || assetsAfter - assetsBefore != returned
        ) {
            revert UnsupportedTokenBehavior();
        }
        if (returned == 0 || returned < p.minAmountsOut[0]) {
            revert InsufficientAssets();
        }
    }

    function deposit(
        Farm calldata farm,
        address token,
        bytes memory extraData
    ) external view override onlyDelegateCall {
        _farm(farm, extraData);
        if (token != farm.stakingContract) revert InvalidVault();
        if (IERC20(token).balanceOf(address(this)) == 0) {
            revert InvalidAmount();
        }
    }

    function withdraw(
        Farm calldata farm,
        uint256 amount,
        bytes memory extraData
    ) external view override onlyDelegateCall {
        _farm(farm, extraData);
        _checkShares(
            amount, IERC20(farm.stakingContract).balanceOf(address(this))
        );
    }

    function claim(
        Farm calldata farm,
        bytes memory extraData
    ) external view override onlyDelegateCall {
        _farm(farm, extraData);
    }

    /// @notice Actual share holdings, for execution; no inferred staked
    /// balance.
    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        _validateFarm(farm);
        return IERC20(farm.stakingContract).balanceOf(user);
    }

    function earned(
        Farm calldata farm,
        address,
        address[] calldata rewards
    ) external view override returns (uint256[] memory) {
        _validateFarm(farm);
        if (rewards.length != 0) revert UnsupportedRewards();
        return new uint256[](0);
    }

    /// @notice Shares are held directly, never staked in a separate farm.
    function isStaked(
        Farm calldata farm,
        address
    ) external view override returns (bool) {
        _validateFarm(farm);
        return false;
    }

    function getTokens(
        address vault
    ) external view override returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = _asset(vault);
    }

    function getReserves(
        address vault
    ) external view override returns (uint256[] memory reserves) {
        _asset(vault);
        reserves = new uint256[](1);
        reserves[0] = _recordedAssets(vault);
    }

    /// @dev Pair-based automatic exits are deliberately unsupported.
    function getPoolPrice(
        address,
        uint256,
        uint256
    ) external pure override returns (uint256) {
        revert UnsupportedPairPrice();
    }

    function _deposit(
        address vault,
        uint256 amount
    ) internal virtual returns (uint256) {
        return IERC4626(vault).deposit(amount, address(this));
    }

    function _redeem(
        address vault,
        uint256 shares
    ) internal virtual returns (uint256) {
        return IERC4626(vault).redeem(shares, address(this), address(this));
    }

    function _validateFarm(
        Farm calldata farm
    ) internal view returns (address) {
        if (farm.poolIndex != 0) revert InvalidPoolIndex();
        return _asset(farm.stakingContract);
    }

    function _farm(
        Farm calldata farm,
        bytes memory extraData
    ) internal view {
        address asset = _validateFarm(farm);
        if (extraData.length != 32) revert InvalidExtraData();
        SingleAssetVaultFarmExtraData memory extra =
            abi.decode(extraData, (SingleAssetVaultFarmExtraData));
        if (extra.asset != asset) revert InvalidAsset();
    }

    function _checkShares(
        uint256 amount,
        uint256 balance
    ) internal pure {
        if (amount == 0 || amount == type(uint256).max || amount > balance) {
            revert InvalidAmount();
        }
    }
}
