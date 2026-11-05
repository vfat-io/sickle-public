// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    UniswapV3Connector
} from "contracts/connectors/uniswap/UniswapV3Connector.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";

interface IPangolinPositionManager {
    function positionReward(
        uint256 tokenId
    )
        external
        view
        returns (
            uint192 rewardPerLiquidityInsideLastX64,
            uint32 rewardLastUpdated,
            uint32 rewardLastCollected,
            uint256 rewardOwed
        );

    function claimReward(
        uint256 tokenId,
        address recipient
    ) external payable;

    function positions(
        uint256 tokenId
    )
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function factory() external view returns (address);
}

interface IPangolinFactory {
    function getPool(
        address token0,
        address token1,
        uint24 fee
    ) external view returns (address);
}

interface IPangolinRewardManager {
    /// @notice What a claim would actually pay for `tokenId`, given the
    /// position's accrued entitlement. Applies the same stored reward debt,
    /// per-token multipliers and balance cap that `claimReward` applies.
    function pendingRewards(
        address pool,
        uint256 tokenId,
        uint256 rewardOwed
    )
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts);
}

contract PangolinV3Connector is UniswapV3Connector {
    /// @dev The reward manager applies a per-pool multiplier that the position
    /// manager does not, and it is reachable only by address: the position
    /// manager stores it in slot 15 and exposes no getter, so a contract cannot
    /// discover it. Pangolin is Avalanche-only, so pin it. `updateRewardManager`
    /// exists on the position manager -- if Pangolin ever calls it, this
    /// constant goes stale and `earned()` starts reverting on the multiplier
    /// read, which is loud rather than silently wrong.
    address internal constant REWARD_MANAGER =
        0xbA19AF51023b02AEC7e0c81499a2a2654aac2F1c;

    /// @notice Pending rewards for the position, as the amounts a claim would
    /// actually pay, indexed to match `rewardTokens`.
    ///
    /// @dev `positionReward().rewardOwed` is the position's live entitlement --
    /// recomputed against the pool on read -- but it is not what arrives.
    /// `claimReward` forwards it to the reward manager, which pays, per
    /// configured reward token, `min(rewardDebt + owed * multiplier / 1e18,
    /// its own balance)`, and stores any shortfall as debt for next time.
    ///
    /// `pendingRewards` applies all of that, so ask rather than reproduce.
    ///
    /// Verified against real claims at block 85601329: tokenId 13668 pays
    /// 29500213805859692483 and 13632 pays 40009137201210163294, both to the
    /// wei.
    function earned(
        address, // user
        NftPosition calldata position,
        address[] memory rewardTokens
    ) external view virtual override returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](rewardTokens.length);
        if (rewardTokens.length == 0) {
            return amounts;
        }

        (address[] memory tokens, uint256[] memory pending) =
            _pending(position);

        // The reward manager reports its own token set; align it to what the
        // caller asked for rather than assuming a single reward or a shared
        // ordering.
        for (uint256 i; i < tokens.length;) {
            for (uint256 j; j < rewardTokens.length;) {
                if (tokens[i] == rewardTokens[j]) {
                    amounts[j] = pending[i];
                    break;
                }
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
        return amounts;
    }

    /// @dev What the reward manager would pay for this position right now.
    ///
    /// Deliberately does NOT short-circuit on a zero entitlement. A claim made
    /// while the reward manager was underfunded stores the shortfall in
    /// `rewardDebts` and pays what it had; the entitlement is then consumed but
    /// the debt survives, so `pendingRewards(pool, tokenId, 0)` stays positive
    /// until the manager is refilled. Returning zero on `owed == 0` would hide
    /// that from the lens and the keeper permanently.
    function _pending(
        NftPosition calldata position
    )
        private
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        // `positionReward` reverts for positions the manager never accrued for
        // -- it is per-position, so an unincentivised token reverts at every
        // block. Reading it unguarded would break the read-only lens for those
        // positions. A revert means no entitlement, not necessarily no debt,
        // so carry on with zero rather than returning early.
        uint256 owed;
        try IPangolinPositionManager(address(position.nft)).positionReward(
            position.tokenId
        ) returns (uint192, uint32, uint32, uint256 rewardOwed) {
            owed = rewardOwed;
        } catch { }

        return IPangolinRewardManager(REWARD_MANAGER).pendingRewards(
            _poolOf(position), position.tokenId, owed
        );
    }

    function _poolOf(
        NftPosition calldata position
    ) private view returns (address) {
        IPangolinPositionManager manager =
            IPangolinPositionManager(address(position.nft));
        (,, address token0, address token1, uint24 fee,,,,,,,) =
            manager.positions(position.tokenId);
        return IPangolinFactory(manager.factory()).getPool(token0, token1, fee);
    }

    function claim(
        NftPosition calldata position,
        address[] memory, // rewardTokens
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata // extraData
    ) external virtual override {
        if (amount0Max > 0 || amount1Max > 0) {
            _collect(position.nft, position.tokenId, amount0Max, amount1Max);
        }
        // Claim on anything the reward manager would actually pay, not on the
        // entitlement alone: stored debt from an underfunded claim is payable
        // with a zero entitlement, and `claimReward` settles it -- the position
        // manager forwards to the reward manager even when it computes zero.
        (, uint256[] memory pending) = _pending(position);
        bool anyPending;
        for (uint256 i; i < pending.length;) {
            if (pending[i] > 0) {
                anyPending = true;
                break;
            }
            unchecked {
                ++i;
            }
        }
        if (anyPending) {
            // Connectors run by delegatecall from the Sickle, so `address(this)`
            // is the Sickle and `msg.sender` is the calling strategy. The
            // recipient must be the Sickle: rewards sent to the strategy are
            // invisible to the fee, zap and sweep steps that follow, and no
            // strategy exposes a recovery path. Matches `_collect` above.
            IPangolinPositionManager(address(position.nft))
                .claimReward(position.tokenId, address(this));
        }
    }
}
