// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {
    StrategyModule,
    SickleFactory,
    Sickle,
    ConnectorRegistry
} from "contracts/modules/StrategyModule.sol";
import { Farm } from "contracts/structs/FarmStrategyStructs.sol";
import {
    PositionKey,
    PositionSettings
} from "contracts/structs/PositionSettingsStructs.sol";
import {
    IVotingEscrowConnector
} from "contracts/interfaces/IVotingEscrowConnector.sol";
import {
    IVotingEscrowAutomation
} from "contracts/interfaces/IVotingEscrowAutomation.sol";
import {
    IMessageFeeAccount
} from "contracts/interfaces/IMessageFeeAccount.sol";
import { VotingEscrowOptions } from "contracts/structs/VotingEscrowStructs.sol";
import {
    INftTransferLib
} from "contracts/interfaces/libraries/INftTransferLib.sol";
import {
    IPositionSettingsLib
} from "contracts/interfaces/libraries/IPositionSettingsLib.sol";
import {
    IPositionSettingsRegistry
} from "contracts/interfaces/IPositionSettingsRegistry.sol";

/// @title VotingEscrowStrategy
/// @notice Holds voting-escrow NFTs (such as sAERO) on their owner's Sickle
/// and votes them. The farm is the escrow, with its farm connector
/// registered against the escrow address.
/// @dev Rewards go through FarmStrategy unchanged: harvest, compound, and
/// the keeper's harvestFor/compoundFor gated by the position settings
/// `deposit` writes. This strategy adds NFT custody, votes (`voteFor`,
/// VE_VOTE) and claims on other chains (`claimRemoteFor`, FARM_HARVEST).
/// Their message fees come from the Sickle's balance in MessageFeeAccount,
/// funded by `msg.value` on deposit and by the connector, which the keeper
/// spends within the owner's `maxMessageFee` and a fixed interval. The
/// strategy holds no state and no funds.
contract VotingEscrowStrategy is StrategyModule, IVotingEscrowAutomation {
    struct Libraries {
        INftTransferLib nftTransferLib;
        IPositionSettingsLib positionSettingsLib;
    }

    event SickleDepositedVotingEscrow(
        Sickle indexed sickle, address indexed votingEscrow, uint256[] tokenIds
    );
    event SickleWithdrewVotingEscrow(
        Sickle indexed sickle, address indexed votingEscrow, uint256[] tokenIds
    );
    event SickleVoted(Sickle indexed sickle, address indexed votingEscrow);
    event SickleClaimedRemote(
        Sickle indexed sickle, address indexed votingEscrow
    );

    error AutoRewardsNotSet();
    error MessageFeeAboveLimit(uint256 fee, uint256 limit);
    error NotFeeAccount();

    bytes32 private constant VOTE_ACTION =
        bytes32(IVotingEscrowAutomation.voteFor.selector);
    bytes32 private constant CLAIM_ACTION =
        bytes32(IVotingEscrowAutomation.claimRemoteFor.selector);

    INftTransferLib public immutable nftTransferLib;
    IPositionSettingsLib public immutable positionSettingsLib;

    /// @notice FarmStrategy's settings registry, whose auto-harvest and
    /// auto-compound settings gate the keeper's reward actions.
    IPositionSettingsRegistry public immutable positionSettingsRegistry;

    IMessageFeeAccount public immutable feeAccount;

    /// @notice Least time between paid keeper votes on one Sickle. Set to the
    /// escrow's vote cooldown: a remote chain, not the root, enforces that
    /// cooldown, so a sooner vote would still send and pay for messages.
    uint256 public immutable remoteVoteInterval;

    /// @notice Least time between paid keeper claims on one Sickle.
    uint256 public immutable remoteClaimInterval;

    constructor(
        SickleFactory factory,
        ConnectorRegistry connectorRegistry,
        Libraries memory libraries,
        IPositionSettingsRegistry positionSettingsRegistry_,
        IMessageFeeAccount feeAccount_,
        uint256 remoteVoteInterval_,
        uint256 remoteClaimInterval_
    ) StrategyModule(factory, connectorRegistry) {
        nftTransferLib = libraries.nftTransferLib;
        positionSettingsLib = libraries.positionSettingsLib;
        positionSettingsRegistry = positionSettingsRegistry_;
        feeAccount = feeAccount_;
        remoteVoteInterval = remoteVoteInterval_;
        remoteClaimInterval = remoteClaimInterval_;
    }

    /// @dev A keeper action's message fee, paid out by the fee account and
    /// forwarded to the Sickle in the same call.
    receive() external payable {
        if (msg.sender != address(feeAccount)) revert NotFeeAccount();
    }

    /**
     * @notice Moves escrow NFTs into the caller's Sickle and sets the farm's
     * position settings. Stake amount, end, permanence and votes are kept.
     * @param farm The escrow, with a registered connector, and pool index.
     * @param tokenIds NFTs to move; the caller must have approved its Sickle.
     * @param settings Reward automation for the farm (auto-harvest or
     * auto-compound), as for FarmStrategy positions. `extraData` holds the
     * owner's VotingEscrowOptions (fee limit and reserve, remote recipients).
     * @param approved The address approved to manage automation (used when
     * deploying a new Sickle only).
     * @param referralCode The referral code for tracking purposes (used when
     * deploying a new Sickle only).
     * @dev `msg.value` funds the Sickle's fee account balance.
     */
    function deposit(
        Farm calldata farm,
        uint256[] calldata tokenIds,
        PositionSettings calldata settings,
        address approved,
        bytes32 referralCode
    ) external payable {
        Sickle sickle = getOrDeploySickle(msg.sender, approved, referralCode);

        _transferIn(sickle, farm, tokenIds);
        _fund(sickle);

        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(positionSettingsLib);
        data[0] = abi.encodeCall(
            IPositionSettingsLib.setPositionSettings,
            (positionSettingsRegistry, farm, settings)
        );
        sickle.multicall(targets, data);
    }

    /**
     * @notice Moves more escrow NFTs into the caller's existing Sickle,
     * keeping the farm's position settings. `msg.value` funds the Sickle's
     * fee account balance.
     */
    function increase(
        Farm calldata farm,
        uint256[] calldata tokenIds
    ) external payable {
        Sickle sickle = getSickle(msg.sender);
        _transferIn(sickle, farm, tokenIds);
        _fund(sickle);
    }

    /**
     * @notice Returns escrow NFTs from the caller's Sickle to the caller.
     * Votes and unclaimed rewards stay with each NFT.
     * @dev Calls neither the connector nor the escrow's voter.
     */
    function withdraw(
        Farm calldata farm,
        uint256[] calldata tokenIds
    ) external {
        Sickle sickle = getSickle(msg.sender);

        uint256 length = tokenIds.length;
        address[] memory targets = new address[](length);
        bytes[] memory data = new bytes[](length);
        for (uint256 i; i < length;) {
            targets[i] = address(nftTransferLib);
            data[i] = abi.encodeCall(
                INftTransferLib.transferErc721ToUser,
                (IERC721(farm.stakingContract), tokenIds[i])
            );
            unchecked {
                i++;
            }
        }
        sickle.multicall(targets, data);

        emit SickleWithdrewVotingEscrow(sickle, farm.stakingContract, tokenIds);
    }

    /**
     * @notice Sets the gauge votes of NFTs in the caller's Sickle.
     * @param extraData Protocol-specific votes, decoded by the connector.
     * @dev `msg.value` pays message fees to other chains.
     */
    function vote(
        Farm calldata farm,
        bytes calldata extraData
    ) external payable {
        _vote(getSickle(msg.sender), farm, extraData, msg.value);
    }

    /// @inheritdoc IVotingEscrowAutomation
    function voteFor(
        Sickle sickle,
        Farm calldata farm,
        bytes calldata extraData,
        uint256 messageFee
    ) external override onlyApproved(sickle) {
        _spendMessageFee(
            sickle, farm, messageFee, VOTE_ACTION, remoteVoteInterval
        );
        _vote(sickle, farm, extraData, messageFee);
    }

    /**
     * @notice Claims rewards of NFTs in the caller's Sickle on other chains,
     * paid there to the owner's recipients.
     * @dev `msg.value` pays the message fees.
     */
    function claimRemote(
        Farm calldata farm,
        bytes calldata extraData
    ) external payable {
        _claimRemote(getSickle(msg.sender), farm, extraData, msg.value);
    }

    /// @inheritdoc IVotingEscrowAutomation
    function claimRemoteFor(
        Sickle sickle,
        Farm calldata farm,
        bytes calldata extraData,
        uint256 messageFee
    ) external override onlyApproved(sickle) {
        if (!_settings(sickle, farm).automateRewards) {
            revert AutoRewardsNotSet();
        }
        _spendMessageFee(
            sickle, farm, messageFee, CLAIM_ACTION, remoteClaimInterval
        );
        _claimRemote(sickle, farm, extraData, messageFee);
    }

    function _transferIn(
        Sickle sickle,
        Farm calldata farm,
        uint256[] calldata tokenIds
    ) private {
        // Only escrows with a registered connector can be voted or claimed.
        connectorRegistry.connectorOf(farm.stakingContract);

        uint256 length = tokenIds.length;
        address[] memory targets = new address[](length);
        bytes[] memory data = new bytes[](length);
        for (uint256 i; i < length;) {
            targets[i] = address(nftTransferLib);
            data[i] = abi.encodeCall(
                INftTransferLib.transferErc721FromUser,
                (IERC721(farm.stakingContract), tokenIds[i])
            );
            unchecked {
                i++;
            }
        }
        sickle.multicall(targets, data);

        emit SickleDepositedVotingEscrow(sickle, farm.stakingContract, tokenIds);
    }

    function _vote(
        Sickle sickle,
        Farm calldata farm,
        bytes calldata extraData,
        uint256 value
    ) private {
        _connectorCall(
            sickle,
            farm,
            abi.encodeCall(IVotingEscrowConnector.vote, (farm, extraData)),
            value
        );
        emit SickleVoted(sickle, farm.stakingContract);
    }

    function _claimRemote(
        Sickle sickle,
        Farm calldata farm,
        bytes calldata extraData,
        uint256 value
    ) private {
        _connectorCall(
            sickle,
            farm,
            abi.encodeCall(
                IVotingEscrowConnector.claimRemote, (farm, extraData)
            ),
            value
        );
        emit SickleClaimedRemote(sickle, farm.stakingContract);
    }

    function _connectorCall(
        Sickle sickle,
        Farm calldata farm,
        bytes memory call,
        uint256 value
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = connectorRegistry.connectorOf(farm.stakingContract);
        data[0] = call;
        sickle.multicall{ value: value }(targets, data);
    }

    /// @dev Takes a keeper action's `messageFee` from the Sickle's fee
    /// account balance, within the owner's `maxMessageFee` (zero: no paid
    /// actions) and at most once per `interval`. Fee-free actions, on the
    /// escrow's own chain, are not limited here.
    function _spendMessageFee(
        Sickle sickle,
        Farm calldata farm,
        uint256 messageFee,
        bytes32 action,
        uint256 interval
    ) private {
        if (messageFee == 0) return;

        uint256 limit = _options(sickle, farm).maxMessageFee;
        if (messageFee > limit) revert MessageFeeAboveLimit(messageFee, limit);

        feeAccount.spend(sickle, messageFee, action, interval);
    }

    function _fund(
        Sickle sickle
    ) private {
        if (msg.value != 0) feeAccount.deposit{ value: msg.value }(sickle);
    }

    function _settings(
        Sickle sickle,
        Farm calldata farm
    ) private view returns (PositionSettings memory) {
        return positionSettingsRegistry.getPositionSettings(
            PositionKey({
                sickle: sickle,
                stakingContract: farm.stakingContract,
                poolIndex: farm.poolIndex
            })
        );
    }

    function _options(
        Sickle sickle,
        Farm calldata farm
    ) private view returns (VotingEscrowOptions memory options) {
        bytes memory data = _settings(sickle, farm).extraData;
        if (data.length != 0) {
            options = abi.decode(data, (VotingEscrowOptions));
        }
    }
}
