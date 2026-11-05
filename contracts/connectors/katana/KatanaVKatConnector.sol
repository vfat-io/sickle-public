// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    IERC721
} from "lib/openzeppelin-contracts/contracts/interfaces/IERC721.sol";
import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import {
    IKatanaAvKatVault
} from "contracts/interfaces/external/katana/IKatanaAvKatVault.sol";
import {
    IKatanaCampaignPayout
} from "contracts/interfaces/external/katana/IKatanaCampaignPayout.sol";
import {
    IKatanaVotingEscrow,
    KatanaLockedBalance
} from "contracts/interfaces/external/katana/IKatanaVotingEscrow.sol";
import {
    KatanaCampaignClaimExtraData,
    KatanaVKatConvertExtraData,
    KatanaVKatExitAction,
    KatanaVKatExitExtraData
} from "contracts/structs/KatanaStructs.sol";

/// @title KatanaVKatConnector
/// @notice Connector for Sickle-owned Katana vKAT lock NFTs.
/// @dev The connector is registered against the vKAT lock NFT address only.
/// `claim()` can optionally claim dashboard campaign payouts first, then
/// converts explicit or newly-claimed vKAT token IDs into transferable avKAT
/// shares held by the Sickle, so FarmStrategy.simpleHarvest can sweep avKAT to
/// the Sickle owner. `withdraw()` routes VotingEscrow exit actions while
/// keeping ownership-sensitive calls in the Sickle context.
contract KatanaVKatConnector is IFarmConnector {
    error InvalidCampaignClaimData();
    error InvalidConvertData();
    error InvalidFarm();
    error InvalidTokenIds();
    error InvalidExitAction();
    error NotSupported();
    error ZeroAddress();

    IKatanaVotingEscrow public immutable votingEscrow;
    IKatanaAvKatVault public immutable avKatVault;
    IKatanaCampaignPayout public immutable campaignPayout;
    IERC721 public immutable vKatLockNft;

    constructor(
        IKatanaVotingEscrow votingEscrow_,
        IKatanaAvKatVault avKatVault_,
        IKatanaCampaignPayout campaignPayout_
    ) {
        if (address(votingEscrow_) == address(0)) revert ZeroAddress();
        if (address(avKatVault_) == address(0)) revert ZeroAddress();
        if (address(campaignPayout_) == address(0)) revert ZeroAddress();

        address lockNft = votingEscrow_.lockNFT();
        if (lockNft == address(0)) revert ZeroAddress();

        votingEscrow = votingEscrow_;
        avKatVault = avKatVault_;
        campaignPayout = campaignPayout_;
        vKatLockNft = IERC721(lockNft);
    }

    function deposit(
        Farm calldata,
        address,
        bytes memory
    ) external pure override {
        revert NotSupported();
    }

    /// @notice Routes VotingEscrow exit actions for Sickle-owned vKAT token
    /// IDs.
    /// @dev For `Withdraw`, use FarmStrategy.simpleWithdraw with lpToken set to
    /// KAT so the withdrawn KAT is swept to the Sickle owner.
    function withdraw(
        Farm calldata farm,
        uint256, // amount
        bytes memory extraData
    ) external override {
        _validateFarm(farm);

        KatanaVKatExitExtraData memory exitData =
            abi.decode(extraData, (KatanaVKatExitExtraData));

        uint256 length = exitData.tokenIds.length;
        if (length == 0) revert InvalidTokenIds();

        for (uint256 i; i < length;) {
            _exit(exitData.action, exitData.tokenIds[i]);
            unchecked {
                i++;
            }
        }
    }

    /// @notice Optionally claims campaign vKAT, then converts Sickle-owned vKAT
    /// lock NFTs into avKAT.
    /// @dev FarmStrategy.simpleHarvest should include avKAT as rewardTokens so
    /// the resulting ERC20 shares are fee-processed and swept to the user.
    function claim(
        Farm calldata farm,
        bytes memory extraData
    ) external override {
        _validateFarm(farm);

        KatanaVKatConvertExtraData memory convertData =
            abi.decode(extraData, (KatanaVKatConvertExtraData));

        bool hasCampaignClaim = _hasCampaignClaim(convertData.campaignClaim);
        if (hasCampaignClaim && convertData.tokenIds.length > 0) {
            revert InvalidConvertData();
        }

        uint256 ownedBeforeClaim;
        if (hasCampaignClaim && convertData.tokenIds.length == 0) {
            ownedBeforeClaim = votingEscrow.ownedTokens(address(this)).length;
        }

        if (hasCampaignClaim) {
            _claimCampaign(convertData.campaignClaim);
        }

        if (convertData.tokenIds.length > 0) {
            _convertTokenIds(convertData.tokenIds);
        } else if (hasCampaignClaim) {
            _convertNewOwnedTokenIds(ownedBeforeClaim);
        } else {
            revert InvalidTokenIds();
        }
    }

    function _claimCampaign(
        KatanaCampaignClaimExtraData memory claimData
    ) internal {
        uint256 length = claimData.campaignIds.length;
        if (
            length == 0 || length != claimData.campaignPayouts.length
                || length != claimData.additionalData.length
        ) {
            revert InvalidCampaignClaimData();
        }

        address[] memory receivers = new address[](length);
        for (uint256 i; i < length;) {
            receivers[i] = address(this);
            unchecked {
                i++;
            }
        }

        campaignPayout.batchClaimCampaignPayout(
            claimData.campaignIds,
            receivers,
            claimData.campaignPayouts,
            claimData.additionalData
        );
    }

    function _convertTokenIds(
        uint256[] memory tokenIds
    ) internal {
        uint256 length = tokenIds.length;
        if (length == 0) revert InvalidTokenIds();

        for (uint256 i; i < length;) {
            _convertTokenId(tokenIds[i]);
            unchecked {
                i++;
            }
        }
    }

    function _convertNewOwnedTokenIds(
        uint256 ownedBeforeClaim
    ) internal {
        uint256[] memory tokenIds = votingEscrow.ownedTokens(address(this));
        uint256 length = tokenIds.length;
        if (length <= ownedBeforeClaim) revert InvalidTokenIds();

        for (uint256 i = ownedBeforeClaim; i < length;) {
            _convertTokenId(tokenIds[i]);
            unchecked {
                i++;
            }
        }
    }

    function _convertTokenId(
        uint256 tokenId
    ) internal {
        vKatLockNft.approve(address(avKatVault), tokenId);
        avKatVault.depositTokenId(tokenId, address(this));
    }

    function _hasCampaignClaim(
        KatanaCampaignClaimExtraData memory claimData
    ) internal pure returns (bool) {
        return claimData.campaignIds.length != 0
            || claimData.campaignPayouts.length != 0
            || claimData.additionalData.length != 0;
    }

    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        _validateFarm(farm);
        return vKatLockNft.balanceOf(user);
    }

    /// @notice Estimates convertible vKAT value for each requested reward
    /// token.
    /// @dev avKAT rewards are reported as expected shares. KAT rewards are
    /// reported as the summed underlying lock amount for Sickle exit views.
    function earned(
        Farm calldata farm,
        address user,
        address[] calldata rewardTokens
    ) external view override returns (uint256[] memory amounts) {
        _validateFarm(farm);

        amounts = new uint256[](rewardTokens.length);
        if (rewardTokens.length == 0) return amounts;

        uint256 assets = _lockedAssets(user);
        if (assets == 0) return amounts;

        uint256 shares = avKatVault.convertToShares(assets);
        address asset = avKatVault.asset();

        for (uint256 i; i < rewardTokens.length;) {
            if (rewardTokens[i] == address(avKatVault)) {
                amounts[i] = shares;
            } else if (rewardTokens[i] == asset) {
                amounts[i] = assets;
            }

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
        return vKatLockNft.balanceOf(user) > 0;
    }

    function _validateFarm(
        Farm calldata farm
    ) internal view {
        if (farm.stakingContract != address(vKatLockNft)) revert InvalidFarm();
    }

    function _lockedAssets(
        address user
    ) internal view returns (uint256 assets) {
        uint256[] memory tokenIds = votingEscrow.ownedTokens(user);
        for (uint256 i; i < tokenIds.length;) {
            KatanaLockedBalance memory locked = votingEscrow.locked(tokenIds[i]);
            assets += locked.amount;

            unchecked {
                i++;
            }
        }
    }

    /// @dev Beginning a withdrawal moves the lock NFT into the VotingEscrow,
    /// so it needs an approval first exactly as the vault deposit does.
    /// Cancel and Withdraw act on a lock the escrow already custodies, and
    /// approving a token the Sickle no longer owns would itself revert, so
    /// the approval is scoped to the two entry actions.
    function _exit(
        KatanaVKatExitAction action,
        uint256 tokenId
    ) internal {
        if (action == KatanaVKatExitAction.BeginWithdrawal) {
            vKatLockNft.approve(address(votingEscrow), tokenId);
            votingEscrow.beginWithdrawal(tokenId);
        } else if (action == KatanaVKatExitAction.ResetVotesAndBeginWithdrawal)
        {
            vKatLockNft.approve(address(votingEscrow), tokenId);
            votingEscrow.resetVotesAndBeginWithdrawal(tokenId);
        } else if (action == KatanaVKatExitAction.CancelWithdrawalRequest) {
            votingEscrow.cancelWithdrawalRequest(tokenId);
        } else if (action == KatanaVKatExitAction.Withdraw) {
            votingEscrow.withdraw(tokenId);
        } else {
            revert InvalidExitAction();
        }
    }
}
