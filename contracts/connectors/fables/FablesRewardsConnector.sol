// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ConnectorRegistry } from "contracts/ConnectorRegistry.sol";
import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import {
    IFablesRewardDistributor
} from "contracts/interfaces/external/fables/IFablesRewardDistributor.sol";
import { DelegateModule } from "contracts/modules/DelegateModule.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";

/// @dev Harvest payload for a Fables position.
///      `cumulativeAmount` / `proof` are the Sickle's leaf in the published
///      Merkle tree (https://www.fables.fi/rewards/proofs.json, keyed by the
///      lowercased Sickle address). Leave the proof empty to harvest swap fees
///      only. `feeClaimExtraData` is forwarded verbatim to the hook connector
///      and carries the `FablesExtraData` that `claimFees` needs.
struct FablesRewardClaimExtraData {
    uint256 cumulativeAmount;
    bytes32[] proof;
    bytes feeClaimExtraData;
}

/// @title FablesRewardsConnector
/// @notice Single-call harvest for Fables: the weekly USDG incentive from the
///         standalone cumulative Merkle distributor, then the accrued v4 swap
///         fees from the hook.
/// @dev Registered against the distributor address, so a Fables `Farm` is
///      `{ stakingContract: distributor, poolIndex: 0 }` while `position.nft`
///      stays the hook. `NftFarmStrategy` resolves this connector from
///      `farm.stakingContract` and the hook connector from `position.nft`;
///      every leg that is not the incentive claim forwards to the latter, so
///      the hook keeps owning deposits, withdrawals, fees and — once Fables
///      wires `setDistributor` at TGE — staking.
contract FablesRewardsConnector is INftFarmConnector, DelegateModule {
    ConnectorRegistry public immutable connectorRegistry;

    constructor(
        ConnectorRegistry connectorRegistry_
    ) {
        connectorRegistry = connectorRegistry_;
    }

    /// @notice Claim the weekly incentive, then the position's swap fees.
    /// @dev Delegatecalled by the Sickle, so `address(this)` is the Sickle and
    ///      is both the credited account and the payout destination.
    function claim(
        NftPosition calldata position,
        address[] memory rewardTokens,
        uint128 maxAmount0,
        uint128 maxAmount1,
        bytes calldata extraData
    ) external virtual override {
        FablesRewardClaimExtraData memory params =
            abi.decode(extraData, (FablesRewardClaimExtraData));

        IFablesRewardDistributor distributor =
            IFablesRewardDistributor(position.farm.stakingContract);

        // The tree is cumulative and the distributor reverts `NothingToClaim()`
        // once a leaf is settled, so a leaf this Sickle has already been paid
        // for is the ordinary state of every harvest after the first in a
        // week, and of every harvest a keeper front-ran. Skipping it is not an
        // edge case. A leaf that fails for any other reason — re-rooted,
        // absent, unfunded — reverts, and the caller retries with a proof
        // refetched from the published tree.
        if (
            params.proof.length != 0
                && distributor.claimed(address(this)) < params.cumulativeAmount
        ) {
            distributor.claim(
                address(this), params.cumulativeAmount, params.proof
            );
        }

        _delegateToLp(
            position,
            abi.encodeCall(
                INftFarmConnector.claim,
                (
                    position,
                    rewardTokens,
                    maxAmount0,
                    maxAmount1,
                    params.feeClaimExtraData
                )
            )
        );
    }

    /// @dev Fables emissions accrue to staked ranges and staking lives on the
    ///      hook, so both legs forward rather than no-op. The hook connector
    ///      reads empty `extraData` as LP-only, which is what the strategy
    ///      sends while the hooks' own `distributor()` is unset; wiring
    ///      staking at TGE is then a change to the hook connector alone.
    function depositExistingNft(
        NftPosition calldata position,
        bytes calldata extraData
    ) external virtual override {
        _delegateToLp(
            position,
            abi.encodeCall(
                INftFarmConnector.depositExistingNft, (position, extraData)
            )
        );
    }

    function withdrawNft(
        NftPosition calldata position,
        bytes calldata extraData
    ) external virtual override {
        _delegateToLp(
            position,
            abi.encodeCall(INftFarmConnector.withdrawNft, (position, extraData))
        );
    }

    /// @dev The incentive is Merkle-gated: the entitlement is only knowable
    ///      with a leaf, which this interface cannot carry. Callers read the
    ///      published tree and `IFablesRewardDistributor.claimable` instead.
    function earned(
        address, // user
        NftPosition calldata,
        address[] memory rewardTokens
    ) external pure override returns (uint256[] memory) {
        return new uint256[](rewardTokens.length);
    }

    function isStaked(
        address user,
        NftPosition calldata position
    ) external view override returns (bool) {
        return
            INftFarmConnector(_lpConnector(position)).isStaked(user, position);
    }

    /// INTERNALS ///

    function _lpConnector(
        NftPosition calldata position
    ) internal view returns (address) {
        return connectorRegistry.connectorOf(address(position.nft));
    }

    /// @dev `_delegateToConnector`, not `_delegateTo`: the hook connector is
    ///      resolved through `ConnectorRegistry`, whose admin is a separate
    ///      role from the one curating the Sickle target whitelist, so it must
    ///      still clear that whitelist before running in the Sickle's context.
    function _delegateToLp(
        NftPosition calldata position,
        bytes memory data
    ) internal {
        _delegateToConnector(_lpConnector(position), data);
    }
}
