// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

import { Sickle } from "contracts/Sickle.sol";
import {
    IMessageFeeAccount
} from "contracts/interfaces/IMessageFeeAccount.sol";
import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import {
    IPositionSettingsRegistry
} from "contracts/interfaces/IPositionSettingsRegistry.sol";
import { PositionKey } from "contracts/structs/PositionSettingsStructs.sol";
import { VotingEscrowOptions } from "contracts/structs/VotingEscrowStructs.sol";
import {
    IVotingEscrowConnector
} from "contracts/interfaces/IVotingEscrowConnector.sol";
import { IWETH9 } from "contracts/interfaces/external/IWETH.sol";
import { IAeroVoter } from "contracts/interfaces/external/aero/IAeroVoter.sol";
import {
    IAeroVotingEscrow
} from "contracts/interfaces/external/aero/IAeroVotingEscrow.sol";
import {
    IAeroLeafVoter,
    IAeroFactoryRegistry
} from "contracts/interfaces/external/aero/IAeroLeafVoter.sol";
import {
    IAeroVotingRewardsManager
} from "contracts/interfaces/external/aero/IAeroVotingRewardsManager.sol";
import {
    AeroVote,
    AeroChainDelta,
    AeroChainGauges,
    AeroRewardsClaim,
    AeroRemoteClaim,
    AeroChainClaim
} from "contracts/structs/AeroVotingEscrowStructs.sol";

/// @title AeroVotingEscrowConnector
/// @notice Connector for Sickle-owned Aero (Dromos MetaDEX V3) sAERO NFTs on
/// Base, registered against the VotingEscrow. The farm is the escrow with
/// pool index 0; the NFTs each call covers are named in `extraData`.
/// @dev Delegatecalled by the Sickle, which owns the NFTs. Base votes and
/// claims run in the same transaction; other chains are reached by Hyperlane
/// messages paid from `msg.value`, and anything unspent or refunded goes
/// back to the Sickle's balance in `feeAccount`. Every mutator requires the
/// Sickle to hold each NFT it names, as the escrow and voter also accept
/// approved operators.
contract AeroVotingEscrowConnector is IFarmConnector, IVotingEscrowConnector {
    error InvalidConfiguration();
    error InvalidFarm();
    error InvalidToken();
    error NotSupported();
    error NotHeld(uint256 tokenId);
    error InsufficientValue(uint256 spent, uint256 provided);
    error LocalChainClaim();
    error NoRemoteRecipient(uint256 chainId);

    /// @dev No cap on the user checkpoints a reward estimate examines; past
    /// the last one the managers also estimate fees not yet notified.
    uint256 private constant ALL_CHECKPOINTS = type(uint256).max;

    IAeroVotingEscrow public immutable votingEscrow;
    IAeroVoter public immutable voter;
    IAeroLeafVoter public immutable leafVoter;
    IAeroFactoryRegistry public immutable factoryRegistry;
    address public immutable aero;
    IWETH9 public immutable weth;
    /// @notice MessageFeeAccount, holding each Sickle's message-fee balance.
    IMessageFeeAccount public immutable feeAccount;
    /// @notice FarmStrategy's settings registry, holding the owner's
    /// VotingEscrowOptions in the farm's `PositionSettings.extraData`.
    IPositionSettingsRegistry public immutable settingsRegistry;

    /// @param leafVoter_ This chain's LeafVoter, whose FactoryRegistry (which
    /// must name it back) lists the gauges `earned` checks.
    constructor(
        IAeroVotingEscrow votingEscrow_,
        IAeroLeafVoter leafVoter_,
        IWETH9 weth_,
        IMessageFeeAccount feeAccount_,
        IPositionSettingsRegistry settingsRegistry_
    ) {
        IAeroVoter voter_ = IAeroVoter(votingEscrow_.VOTER());
        IAeroFactoryRegistry factoryRegistry_ = leafVoter_.FACTORY_REGISTRY();
        if (
            voter_.VOTING_ESCROW() != address(votingEscrow_)
                || factoryRegistry_.leafVoter() != address(leafVoter_)
                || address(weth_) == address(0)
                || address(feeAccount_) == address(0)
                || address(settingsRegistry_) == address(0)
        ) revert InvalidConfiguration();

        votingEscrow = votingEscrow_;
        voter = voter_;
        leafVoter = leafVoter_;
        factoryRegistry = factoryRegistry_;
        aero = votingEscrow_.TOKEN();
        weth = weth_;
        feeAccount = feeAccount_;
        settingsRegistry = settingsRegistry_;
    }

    /// @notice Add the Sickle's whole AERO balance to the stake of the NFT
    /// encoded in `extraData` (`uint256 tokenId`), keeping its end and mode.
    /// @param token AERO, or zero when FarmStrategy.compound passes a zap's
    /// empty LP token.
    function deposit(
        Farm calldata farm,
        address token,
        bytes memory extraData
    ) external override {
        _validateFarm(farm);
        if (token != address(0) && token != aero) revert InvalidToken();

        uint256 tokenId = abi.decode(extraData, (uint256));
        _requireHeld(tokenId);
        uint256 amount = IERC20(aero).balanceOf(address(this));

        // The escrow pulls exactly `amount`, so no allowance is left.
        SafeTransferLib.safeApprove(aero, address(votingEscrow), amount);
        votingEscrow.increaseStakeAmount(tokenId, SafeCast.toUint128(amount));
    }

    /// @notice Not supported: NFTs leave the Sickle whole, through
    /// VotingEscrowStrategy.withdraw.
    function withdraw(
        Farm calldata,
        uint256,
        bytes memory
    ) external pure override {
        revert NotSupported();
    }

    /// @notice Claim the Base fee and incentive rewards encoded in `extraData`
    /// (`AeroRewardsClaim[]`) to the Sickle. WETH rewards arrive as ETH: they
    /// first top the Sickle's fee balance up to the owner's reserve target,
    /// and the rest is wrapped so FarmStrategy fees and sweeps see WETH.
    function claim(
        Farm calldata farm,
        bytes calldata extraData
    ) external override {
        _validateFarm(farm);

        AeroRewardsClaim[] memory claims =
            abi.decode(extraData, (AeroRewardsClaim[]));

        uint256 nativeBefore = address(this).balance;
        for (uint256 i; i < claims.length;) {
            _claim(claims[i]);
            unchecked {
                i++;
            }
        }

        uint256 received = address(this).balance - nativeBefore;
        if (received == 0) return;
        uint256 topUp = _feeTopUp(farm, received);
        if (topUp != 0) feeAccount.deposit{ value: topUp }(_sickle());
        if (received > topUp) weth.deposit{ value: received - topUp }();
    }

    /// @notice Set the gauge votes encoded in `extraData` (`AeroVote[]`),
    /// paying remote message fees from `msg.value`.
    function vote(
        Farm calldata farm,
        bytes calldata extraData
    ) external payable override {
        _validateFarm(farm);
        uint256 start = address(this).balance - msg.value;

        AeroVote[] memory votes = abi.decode(extraData, (AeroVote[]));
        uint256 spent;
        for (uint256 i; i < votes.length;) {
            spent += _allocate(votes[i]);
            unchecked {
                i++;
            }
        }
        _settle(start, spent, msg.value);
    }

    /// @notice Claim the remote rewards encoded in `extraData`
    /// (`AeroRemoteClaim[]`), paying message fees from `msg.value`.
    function claimRemote(
        Farm calldata farm,
        bytes calldata extraData
    ) external payable override {
        _validateFarm(farm);
        uint256 start = address(this).balance - msg.value;

        AeroRemoteClaim[] memory claims =
            abi.decode(extraData, (AeroRemoteClaim[]));
        VotingEscrowOptions memory options = _options(farm);
        address owner = _sickle().owner();
        uint256 spent;
        for (uint256 i; i < claims.length;) {
            spent += _claimRemote(claims[i], options, owner);
            unchecked {
                i++;
            }
        }
        _settle(start, spent, msg.value);
    }

    /// @return Total AERO staked in the NFTs `user` holds.
    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        _validateFarm(farm);

        uint256 total;
        uint256 count = votingEscrow.balanceOf(user);
        for (uint256 i; i < count;) {
            total += votingEscrow.staked(
                votingEscrow.tokenOfOwnerByIndex(user, i)
            )
            .amount;
            unchecked {
                i++;
            }
        }
        return total;
    }

    /// @notice Pending fees and incentives of the NFTs `user` holds, summed
    /// per `rewardTokens` entry. WETH rewards count as WETH, as `claim` wraps
    /// them; tokens not listed are ignored.
    /// @dev Rewards stay claimable on a gauge after its NFT re-votes, so every
    /// gauge the FactoryRegistry lists is checked, not only current votes.
    /// A manager is priced only for NFTs that ever had weight on it.
    function earned(
        Farm calldata farm,
        address user,
        address[] calldata rewardTokens
    ) external view override returns (uint256[] memory amounts) {
        _validateFarm(farm);

        amounts = new uint256[](rewardTokens.length);
        uint256 count = votingEscrow.balanceOf(user);
        if (count == 0) return amounts;
        uint256[] memory tokenIds = new uint256[](count);
        for (uint256 i; i < count;) {
            tokenIds[i] = votingEscrow.tokenOfOwnerByIndex(user, i);
            unchecked {
                i++;
            }
        }

        address[] memory factories = factoryRegistry.gaugeFactories();
        for (uint256 i; i < factories.length;) {
            _addFactoryEarned(factories[i], tokenIds, rewardTokens, amounts);
            unchecked {
                i++;
            }
        }
    }

    function isStaked(
        Farm calldata farm,
        address user
    ) external view override returns (bool) {
        _validateFarm(farm);
        return votingEscrow.balanceOf(user) > 0;
    }

    function _addFactoryEarned(
        address gaugeFactory,
        uint256[] memory tokenIds,
        address[] calldata rewardTokens,
        uint256[] memory amounts
    ) internal view {
        address[] memory gauges = factoryRegistry.factoryToGauges(gaugeFactory);
        for (uint256 i; i < gauges.length;) {
            IAeroVotingRewardsManager manager = IAeroVotingRewardsManager(
                factoryRegistry.gaugeToRewards(gauges[i])
            );
            if (address(manager) != address(0)) {
                for (uint256 j; j < tokenIds.length;) {
                    if (manager.userRewardCheckpointIndex(tokenIds[j]) != 0) {
                        _addEarned(manager, tokenIds[j], rewardTokens, amounts);
                    }
                    unchecked {
                        j++;
                    }
                }
            }
            unchecked {
                i++;
            }
        }
    }

    function _addEarned(
        IAeroVotingRewardsManager manager,
        uint256 tokenId,
        address[] calldata rewardTokens,
        uint256[] memory amounts
    ) internal view {
        (uint256 fee0, uint256 fee1) =
            manager.earnedFees(tokenId, ALL_CHECKPOINTS);
        _add(rewardTokens, amounts, manager.token0(), fee0);
        _add(rewardTokens, amounts, manager.token1(), fee1);

        uint256 programs = manager.incentiveCount();
        for (uint256 programId = 1; programId <= programs;) {
            uint256 amount =
                manager.earnedIncentives(tokenId, programId, ALL_CHECKPOINTS);
            if (amount != 0) {
                _add(
                    rewardTokens,
                    amounts,
                    manager.incentive(programId).token,
                    amount
                );
            }
            unchecked {
                programId++;
            }
        }
    }

    function _add(
        address[] calldata rewardTokens,
        uint256[] memory amounts,
        address token,
        uint256 amount
    ) internal pure {
        for (uint256 i; i < rewardTokens.length;) {
            if (rewardTokens[i] == token) {
                amounts[i] += amount;
                return;
            }
            unchecked {
                i++;
            }
        }
    }

    function _claim(
        AeroRewardsClaim memory c
    ) internal {
        _requireHeld(c.tokenId);
        IAeroVoter.ClaimRewardsParams[] memory params =
            new IAeroVoter.ClaimRewardsParams[](1);
        params[0] = IAeroVoter.ClaimRewardsParams({
            chainId: block.chainid,
            gasLimit: 0,
            value: 0,
            recipient: address(this),
            feeClaims: c.feeClaims,
            incentiveClaims: c.incentiveClaims
        });
        voter.claimRewards(c.tokenId, params, address(this));
    }

    /// @return value The message fees this vote pays.
    function _allocate(
        AeroVote memory v
    ) internal returns (uint256 value) {
        _requireHeld(v.tokenId);

        uint256 length = v.chainDeltas.length;
        IAeroVoter.ChainAllocationDispatch[] memory chainDispatches =
            new IAeroVoter.ChainAllocationDispatch[](length);
        for (uint256 i; i < length;) {
            AeroChainDelta memory d = v.chainDeltas[i];
            chainDispatches[i] = IAeroVoter.ChainAllocationDispatch({
                chainId: d.chainId,
                delta: d.delta,
                gasLimit: d.gasLimit,
                value: d.value
            });
            value += d.value;
            unchecked {
                i++;
            }
        }

        length = v.chainGauges.length;
        IAeroVoter.GaugeAllocationDispatch[] memory gaugeDispatches =
            new IAeroVoter.GaugeAllocationDispatch[](length);
        for (uint256 i; i < length;) {
            gaugeDispatches[i] = _gaugeDispatch(v.chainGauges[i]);
            value += v.chainGauges[i].value;
            unchecked {
                i++;
            }
        }

        voter.allocate{ value: value }(
            v.tokenId, chainDispatches, gaugeDispatches, address(this)
        );
    }

    /// @dev Copies one chain's gauge distribution with empty per-gauge data.
    function _gaugeDispatch(
        AeroChainGauges memory c
    ) internal pure returns (IAeroVoter.GaugeAllocationDispatch memory) {
        uint256 length = c.gauges.length;
        IAeroVoter.GaugeAllocation[] memory gauges =
            new IAeroVoter.GaugeAllocation[](length);
        for (uint256 i; i < length;) {
            gauges[i].gauge = c.gauges[i].gauge;
            gauges[i].allocated = c.gauges[i].allocated;
            unchecked {
                i++;
            }
        }
        return IAeroVoter.GaugeAllocationDispatch({
            chainId: c.chainId,
            gasLimit: c.gasLimit,
            value: c.value,
            gauges: gauges
        });
    }

    /// @return value The message fees this claim pays.
    function _claimRemote(
        AeroRemoteClaim memory c,
        VotingEscrowOptions memory options,
        address owner
    ) internal returns (uint256 value) {
        _requireHeld(c.tokenId);

        uint256 length = c.chains.length;
        IAeroVoter.ClaimRewardsParams[] memory params =
            new IAeroVoter.ClaimRewardsParams[](length);
        for (uint256 i; i < length;) {
            AeroChainClaim memory chain = c.chains[i];
            // Base rewards go through `claim`, so FarmStrategy fees and
            // sweeps apply to them.
            if (chain.chainId == block.chainid) revert LocalChainClaim();
            params[i] = IAeroVoter.ClaimRewardsParams({
                chainId: chain.chainId,
                gasLimit: chain.gasLimit,
                value: chain.value,
                recipient: _remoteRecipient(options, chain.chainId, owner),
                feeClaims: chain.feeClaims,
                incentiveClaims: chain.incentiveClaims
            });
            value += chain.value;
            unchecked {
                i++;
            }
        }

        voter.claimRewards{ value: value }(c.tokenId, params, address(this));
    }

    /// @dev Message fees may only come from this call's value, never from
    /// the Sickle's own balance. Whatever is left, including the transports'
    /// refunds, is returned to the Sickle's fee account balance.
    function _settle(
        uint256 start,
        uint256 spent,
        uint256 provided
    ) internal {
        if (spent > provided) revert InsufficientValue(spent, provided);
        uint256 leftover = address(this).balance - start;
        if (leftover != 0) feeAccount.deposit{ value: leftover }(_sickle());
    }

    /// @dev The owner's recipient for `chainId`, else the owner when it is an
    /// externally owned account (including an EIP-7702 delegated one), whose
    /// address it controls on every chain. A contract owner, such as a Safe,
    /// may not exist at the same address elsewhere, so it must name one.
    function _remoteRecipient(
        VotingEscrowOptions memory options,
        uint256 chainId,
        address owner
    ) internal view returns (address) {
        uint256 length = options.remoteRecipients.length;
        for (uint256 i; i < length;) {
            if (options.remoteRecipients[i].chainId == chainId) {
                return options.remoteRecipients[i].recipient;
            }
            unchecked {
                i++;
            }
        }
        if (_isExternallyOwned(owner)) return owner;
        revert NoRemoteRecipient(chainId);
    }

    function _isExternallyOwned(
        address account
    ) internal view returns (bool) {
        bytes memory code = account.code;
        return code.length == 0
            || (code.length == 23
                && code[0] == 0xef
                && code[1] == 0x01
                && code[2] == 0x00);
    }

    /// @dev Native amount of `received` that brings the fee balance up to the
    /// owner's reserve target.
    function _feeTopUp(
        Farm calldata farm,
        uint256 received
    ) internal view returns (uint256) {
        uint256 target = _options(farm).feeReserveTarget;
        uint256 balance = feeAccount.balanceOf(_sickle());
        if (target <= balance) return 0;
        uint256 missing = target - balance;
        return missing < received ? missing : received;
    }

    function _options(
        Farm calldata farm
    ) internal view returns (VotingEscrowOptions memory options) {
        bytes memory data =
            settingsRegistry.getPositionSettings(
            PositionKey({
                sickle: _sickle(),
                stakingContract: farm.stakingContract,
                poolIndex: farm.poolIndex
            })
        )
        .extraData;
        if (data.length != 0) {
            options = abi.decode(data, (VotingEscrowOptions));
        }
    }

    function _sickle() internal view returns (Sickle) {
        return Sickle(payable(address(this)));
    }

    function _requireHeld(
        uint256 tokenId
    ) internal view {
        if (votingEscrow.ownerOf(tokenId) != address(this)) {
            revert NotHeld(tokenId);
        }
    }

    function _validateFarm(
        Farm calldata farm
    ) internal view {
        if (farm.stakingContract != address(votingEscrow)) {
            revert InvalidFarm();
        }
    }
}
