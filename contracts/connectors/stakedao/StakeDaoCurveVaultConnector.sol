// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IFarmConnector, Farm } from "contracts/interfaces/IFarmConnector.sol";
import {
    IStakeDaoRewardVault
} from "contracts/interfaces/external/stakedao/IStakeDaoRewardVault.sol";
import {
    IStakeDaoAccountant,
    StakeDaoVaultData,
    StakeDaoAccountData
} from "contracts/interfaces/external/stakedao/IStakeDaoAccountant.sol";
import {
    IStakeDaoProtocolController
} from "contracts/interfaces/external/stakedao/IStakeDaoProtocolController.sol";
import {
    ICurveMinter
} from "contracts/interfaces/external/curve/ICurveMinter.sol";
import {
    CurveCrvRewards
} from "contracts/connectors/curve/CurveCrvRewards.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

/// @notice `claim` extraData. Empty extraData means `harvest: true`.
/// @param harvest Harvest the gauge's CRV into the vault before claiming.
/// Without it only CRV the Accountant has already credited is paid, which for
/// a quiet vault can be nothing at all; with it the Sickle also collects the
/// harvest fee, at the cost of the Minter call.
struct StakeDaoClaimExtraData {
    bool harvest;
}

/// @title Farm connector for Stake DAO V2 Curve reward vaults on Ethereum.
///
/// @notice `Farm.stakingContract` is the RewardVault. Depositing pays the
/// Curve LP into the vault, which forwards it to the Stake DAO Locker; the
/// Curve Strategy then stakes it in the gauge through the Locker. Vault shares
/// are 1:1 with LP and are held by the Sickle.
///
/// Rewards come from two places. CRV, boosted by the Locker's veCRV, is paid
/// by the Accountant against the vault's gauge. Extra reward tokens are
/// streamed by the vault itself.
///
/// @dev The connector runs by delegatecall from the Sickle, so every external
/// call is made as the Sickle and all configuration is immutable. A vault is
/// accepted only when the ProtocolController names it as its gauge's vault and
/// it reports the Curve protocol id and the Accountant pinned here. The vault
/// address is never trusted on its own.
contract StakeDaoCurveVaultConnector is IFarmConnector {
    error InvalidVault(address vault);
    error InvalidToken();
    error InvalidAccountant();
    error InvalidMinter();

    /// @notice `bytes4(keccak256("CURVE"))`, Stake DAO's Curve protocol id.
    bytes4 public constant PROTOCOL_ID = bytes4(keccak256("CURVE"));

    /// @dev `IAccountant.NoPendingRewards()`: a claim with nothing to pay.
    bytes4 private constant NO_PENDING_REWARDS =
        bytes4(keccak256("NoPendingRewards()"));

    IStakeDaoProtocolController public immutable protocolController;
    IStakeDaoAccountant public immutable accountant;

    /// @notice The Accountant's reward token (CRV), and the Curve Minter and
    /// GaugeController used to price what a harvest would mint.
    address public immutable crv;
    address public immutable minter;
    address public immutable gaugeController;

    constructor(
        IStakeDaoProtocolController protocolController_,
        address minter_
    ) {
        address accountant_ = protocolController_.accountant(PROTOCOL_ID);
        if (accountant_ == address(0)) revert InvalidAccountant();

        address crv_ = IStakeDaoAccountant(accountant_).REWARD_TOKEN();
        if (minter_ == address(0) || ICurveMinter(minter_).token() != crv_) {
            revert InvalidMinter();
        }

        protocolController = protocolController_;
        accountant = IStakeDaoAccountant(accountant_);
        crv = crv_;
        minter = minter_;
        gaugeController = ICurveMinter(minter_).controller();
    }

    /// @notice The gauge `vault` stakes into, or zero when `vault` is not a
    /// Stake DAO Curve vault on the pinned Accountant.
    /// @dev Every call into `vault` is a length-checked staticcall, so an
    /// arbitrary target resolves to zero rather than reverting.
    function gaugeOf(
        address vault
    ) public view returns (address gauge) {
        uint256 word = _staticWord(vault, IStakeDaoRewardVault.gauge.selector);
        if (word == 0 || word > type(uint160).max) return address(0);
        gauge = address(uint160(word));
        if (protocolController.vault(gauge) != vault) return address(0);

        if (
            _staticWord(vault, IStakeDaoRewardVault.PROTOCOL_ID.selector)
                    != uint256(bytes32(PROTOCOL_ID))
                || _staticWord(vault, IStakeDaoRewardVault.ACCOUNTANT.selector)
                    != uint256(uint160(address(accountant)))
        ) {
            return address(0);
        }
    }

    /// @dev The raw return word of a no-argument staticcall, or zero when the
    /// call fails or returns anything but one word. Read raw rather than
    /// through `abi.decode`, which would revert on a word that is not a clean
    /// address or bytes4 and so fail the lookup instead of rejecting it.
    function _staticWord(
        address target,
        bytes4 selector
    ) private view returns (uint256) {
        (bool ok, bytes memory data) =
            target.staticcall(abi.encodeWithSelector(selector));
        if (!ok || data.length != 32) return 0;
        return abi.decode(data, (uint256));
    }

    function isVault(
        address vault
    ) external view returns (bool) {
        return gaugeOf(vault) != address(0);
    }

    function deposit(
        Farm calldata farm,
        address token,
        bytes memory // extraData
    ) external override {
        address vault = farm.stakingContract;
        _requireGauge(vault);
        if (token != IStakeDaoRewardVault(vault).asset()) {
            revert InvalidToken();
        }

        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount > 0) {
            // The vault pulls exactly `amount`, so the allowance returns to 0.
            SafeTransferLib.safeApprove(token, vault, amount);
            IStakeDaoRewardVault(vault).deposit(amount, address(this));
        }
    }

    function withdraw(
        Farm calldata farm,
        uint256 amount,
        bytes memory // extraData
    ) external override {
        _requireGauge(farm.stakingContract);
        IStakeDaoRewardVault(farm.stakingContract)
            .withdraw(amount, address(this), address(this));
    }

    /// @notice Claims CRV from the Accountant and every extra reward token the
    /// vault streams. See `StakeDaoClaimExtraData` for `extraData`.
    function claim(
        Farm calldata farm,
        bytes memory extraData
    ) external override {
        address vault = farm.stakingContract;
        address gauge = _requireGauge(vault);

        bool harvest = extraData.length == 0
            || abi.decode(extraData, (StakeDaoClaimExtraData)).harvest;

        address[] memory gauges = new address[](1);
        gauges[0] = gauge;
        // One empty entry per gauge harvests CRV only. A non-empty entry would
        // also push the gauge's extra rewards to the vault's RewardReceiver,
        // which pays this Sickle nothing until someone distributes them.
        bytes[] memory harvestData = new bytes[](harvest ? 1 : 0);

        // The Accountant reverts rather than paying zero. A position with no
        // CRV due must still be able to claim its extra rewards, so swallow
        // exactly that error and bubble every other one.
        try accountant.claim(gauges, harvestData) { }
        catch (bytes memory reason) {
            if (reason.length != 4 || bytes4(reason) != NO_PENDING_REWARDS) {
                assembly {
                    revert(add(reason, 32), mload(reason))
                }
            }
        }

        address[] memory rewardTokens =
            IStakeDaoRewardVault(vault).getRewardTokens();
        if (rewardTokens.length > 0) {
            IStakeDaoRewardVault(vault).claim(rewardTokens, address(this));
        }
    }

    function balanceOf(
        Farm calldata farm,
        address user
    ) external view override returns (uint256) {
        _requireGauge(farm.stakingContract);
        return IStakeDaoRewardVault(farm.stakingContract).balanceOf(user);
    }

    /// @notice What `claim` with the default (harvesting) extraData pays.
    /// @dev For CRV this is `user`'s Accountant credit after the harvest the
    /// claim runs, plus the harvest fee that harvest pays the caller. The
    /// harvested amount is the CRV the Locker can mint from the gauge, read
    /// through `CurveCrvRewards`, which is exact while the GaugeController is
    /// checkpointed and a lower bound past that. Sidecar rewards (Convex, for
    /// vaults the allocator splits) are left out. Both shortfalls only ever
    /// under-report; nothing here can read higher than the claim pays.
    function earned(
        Farm calldata farm,
        address user,
        address[] calldata rewardTokens
    ) external view override returns (uint256[] memory rewards) {
        address vault = farm.stakingContract;
        address gauge = _requireGauge(vault);

        rewards = new uint256[](rewardTokens.length);
        for (uint256 i; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            if (token == crv) {
                rewards[i] = _claimableCrv(vault, gauge, user);
            } else if (IStakeDaoRewardVault(vault).isRewardToken(token)) {
                rewards[i] = IStakeDaoRewardVault(vault).earned(user, token);
            }
        }
    }

    function isStaked(
        Farm calldata,
        address // user
    ) external pure override returns (bool) {
        return true;
    }

    /// @dev `Accountant.claim` with one harvest entry: `_harvest` for this
    /// gauge, then `_claim` for `user`. Mirrors the same operations in the same
    /// order so the floors land identically.
    function _claimableCrv(
        address vault,
        address gauge,
        address user
    ) private view returns (uint256) {
        (uint256 integral, uint256 harvesterFee) =
            _integralAfterHarvest(vault, gauge);

        StakeDaoAccountData memory account = accountant.accounts(vault, user);
        uint256 claimable = account.pendingRewards;
        if (integral > account.integral) {
            claimable += (integral - account.integral) * account.balance
                / accountant.SCALING_FACTOR();
        }

        // With nothing due the claim reverts and the harvest, fee included,
        // unwinds with it.
        return claimable == 0 ? 0 : claimable + harvesterFee;
    }

    /// @dev `Accountant._harvest` for one gauge: the vault integral after it,
    /// and the harvest fee it pays the caller.
    function _integralAfterHarvest(
        address vault,
        address gauge
    ) private view returns (uint256 integral, uint256 harvesterFee) {
        StakeDaoVaultData memory data = accountant.vaults(vault);
        integral = data.integral;

        uint256 harvested = CurveCrvRewards.claimable(
            gauge,
            protocolController.locker(PROTOCOL_ID),
            gaugeController,
            minter,
            crv
        );

        // `_harvest` skips a gauge that reports nothing, and reverts when the
        // report falls short of what checkpoints already recorded or credited.
        // A lower-bound estimate can land there; credit nothing rather than
        // guess.
        uint256 reserved = uint256(data.reservedProtocolFee)
            + data.reservedHarvestFee + data.netCredited;
        if (
            harvested == 0 || harvested < data.totalAmount
                || harvested < reserved
        ) {
            return (integral, 0);
        }

        harvesterFee = data.reservedHarvestFee;

        uint256 newRewards = harvested - reserved;
        if (newRewards == 0 || data.supply == 0) {
            return (integral, harvesterFee);
        }

        uint256 newHarvesterFee =
            newRewards * accountant.getHarvestFeePercent() / 1e18;
        harvesterFee += newHarvesterFee;

        // All of a locker-only harvest is fee-subject.
        if (harvested > data.feeSubjectAmount) {
            newRewards -= (harvested - data.feeSubjectAmount)
                * accountant.getProtocolFeePercent() / 1e18;
        }

        integral += (newRewards - newHarvesterFee) * accountant.SCALING_FACTOR()
            / data.supply;
    }

    function _requireGauge(
        address vault
    ) private view returns (address gauge) {
        gauge = gaugeOf(vault);
        if (gauge == address(0)) revert InvalidVault(vault);
    }
}
