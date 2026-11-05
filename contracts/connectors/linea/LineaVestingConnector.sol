// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { INftFarmConnector } from "contracts/interfaces/INftFarmConnector.sol";
import { NftPosition } from "contracts/structs/NftFarmStrategyStructs.sol";
import { IShadowNonfungiblePositionManager } from
    "contracts/interfaces/external/shadow/IShadowNonfungiblePositionManager.sol";
import { IShadowGaugeV3 } from
    "contracts/interfaces/external/shadow/IShadowGaugeV3.sol";
import { IEtherexVoter } from
    "contracts/connectors/etherex/EtherexV3Connector.sol";

interface ILineaVesting {
    function release() external;
    function releasable(
        address _beneficiary
    ) external view returns (uint256 releasableAmount);
}

error InvalidLineaVestingConfiguration();
error UnsupportedLineaVestingContract(address vestingContract);

struct LineaVestingExtraData {
    bool hasGauge;
    address[] rewardTokens;
    bool claimCounterpartVesting;
}

/// @title LineaVestingConnector
/// @notice Connector for Linea's vesting contract with optional Etherex gauge
/// rewards
/// @dev Implements INftFarmConnector interface for compatibility with NFT farm
/// strategies Note: deposit and withdraw are no-ops as this is a vesting
/// contract
contract LineaVestingConnector is INftFarmConnector {
    IEtherexVoter public immutable voter;
    ILineaVesting public immutable vestingContract;
    ILineaVesting public immutable secondVestingContract;

    constructor(
        IEtherexVoter _voter,
        ILineaVesting _vestingContract,
        ILineaVesting _secondVestingContract
    ) {
        if (
            address(_vestingContract) == address(0)
                || address(_secondVestingContract) == address(0)
                || _vestingContract == _secondVestingContract
        ) {
            revert InvalidLineaVestingConfiguration();
        }
        voter = _voter;
        vestingContract = _vestingContract;
        secondVestingContract = _secondVestingContract;
    }
    /// @notice Deposits are not supported for vesting contracts
    function depositExistingNft(
        NftPosition calldata,
        bytes calldata // extraData
    ) external pure override { }

    /// @notice Withdrawals are not supported for vesting contracts
    function withdrawNft(
        NftPosition calldata,
        bytes calldata // extraData
    ) external pure override { }

    /// @notice Claims vested tokens from a pinned Linea vesting contract and,
    /// when requested, its pinned counterpart; optionally claims Etherex gauge
    /// rewards
    /// @param position The NFT position containing either pinned vesting
    /// contract as its primary address
    /// @param extraData Encoded LineaVestingExtraData; it can opt into the
    /// immutable counterpart but never supplies a vesting call target
    function claim(
        NftPosition calldata position,
        address[] memory, // rewardTokens
        uint128, // maxAmount0
        uint128, // maxAmount1
        bytes calldata extraData
    ) external override {
        LineaVestingExtraData memory extra =
            abi.decode(extraData, (LineaVestingExtraData));

        // The source farm is owner-bound by MultiCompoundSettingsRegistry.
        // Resolve both call targets solely from constructor immutables.
        ILineaVesting primary = ILineaVesting(position.farm.stakingContract);
        if (!_isSupportedVestingContract(primary)) {
            revert UnsupportedLineaVestingContract(address(primary));
        }
        if (primary.releasable(address(this)) > 0) {
            primary.release();
        }

        if (extra.claimCounterpartVesting) {
            ILineaVesting counterpart = primary == vestingContract
                ? secondVestingContract
                : vestingContract;
            if (counterpart.releasable(address(this)) > 0) {
                counterpart.release();
            }
        }

        // Optionally claim REX from Etherex gauge
        if (extra.hasGauge) {
            IShadowNonfungiblePositionManager(address(position.nft)).getReward(
                position.tokenId, extra.rewardTokens
            );
        }
    }

    function _isSupportedVestingContract(
        ILineaVesting candidate
    ) private view returns (bool) {
        return
            candidate == vestingContract || candidate == secondVestingContract;
    }

    /// @notice Returns vested LINEA tokens and optionally Etherex gauge rewards
    /// @param user The address to check vested amount for
    /// @param position The NFT position containing the vesting contract address
    /// @param rewardTokens Array of reward tokens (first is LINEA, rest are
    /// gauge rewards)
    /// @return amounts Array of claimable amounts (LINEA + gauge rewards)
    function earned(
        address user,
        NftPosition calldata position,
        address[] memory rewardTokens
    ) external view override returns (uint256[] memory amounts) {
        amounts = new uint256[](rewardTokens.length);

        if (rewardTokens.length == 0) {
            return amounts;
        }

        // First reward token is LINEA releasable from this position's pinned
        // primary vesting contract. earned() has no claim extraData, so it does
        // not assume the optional counterpart claim was requested.
        ILineaVesting primary = ILineaVesting(position.farm.stakingContract);
        if (!_isSupportedVestingContract(primary)) {
            revert UnsupportedLineaVestingContract(address(primary));
        }
        amounts[0] = primary.releasable(user);

        // Remaining reward tokens are from Etherex gauge (if any)
        if (rewardTokens.length > 1) {
            IShadowNonfungiblePositionManager nft =
                IShadowNonfungiblePositionManager(address(position.nft));
            (address token0, address token1, int24 tickSpacing,,,,,,,) =
                nft.positions(position.tokenId);
            address gauge = voter.gaugeForClPool(token0, token1, tickSpacing);

            if (gauge != address(0)) {
                for (uint256 i = 1; i < rewardTokens.length; i++) {
                    amounts[i] = IShadowGaugeV3(gauge).earned(
                        rewardTokens[i], position.tokenId
                    );
                }
            }
        }
    }

    /// @notice Always returns false as vesting positions are not "staked"
    /// @return false
    function isStaked(
        address, // user
        NftPosition calldata
    ) external pure override returns (bool) {
        return false;
    }
}
