// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    INftFarmConnector,
    NftPosition
} from "contracts/interfaces/INftFarmConnector.sol";
import {
    IHybraClGauge
} from "contracts/interfaces/external/hybra/IHybraClGauge.sol";
import {
    IHybraGaugeManager
} from "contracts/interfaces/external/hybra/IHybraGaugeManager.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract HybraV3GaugeConnector is INftFarmConnector {
    function depositExistingNft(
        NftPosition calldata position,
        bytes calldata
    ) external {
        IERC721(address(position.nft))
            .approve(position.farm.stakingContract, position.tokenId);
        IHybraClGauge(position.farm.stakingContract).deposit(position.tokenId);
    }

    function withdrawNft(
        NftPosition calldata position,
        bytes calldata
    ) external {
        IHybraClGauge(position.farm.stakingContract)
            .withdraw(position.tokenId, 0);
    }

    /// @dev The gauge's `getReward` is restricted to its `DISTRIBUTION` (the
    /// GaugeManager), which claims for `msg.sender`'s stake. Redeem type 0
    /// pays HYBR at rHYBR's `fixedConversionRate`, as `withdraw(tokenId, 0)`
    /// did, without unstaking and restaking the NFT.
    function claim(
        NftPosition calldata position,
        address[] memory,
        uint128,
        uint128,
        bytes calldata
    ) external {
        address gauge = position.farm.stakingContract;
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = position.tokenId;
        IHybraGaugeManager(IHybraClGauge(gauge).DISTRIBUTION())
            .claimRewards(gauge, tokenIds, 0);
    }

    /// @dev Only callable by the Sickle that staked the position: the gauge
    /// resolves staked-ness from `msg.sender`, so every other caller reverts
    /// "Not Staked". ConnectorLens therefore cannot quote pending Hybra
    /// rewards, and the position read reverts with it. Left unguarded: a
    /// swallowed revert would report zero pending, which reads as "nothing to
    /// harvest" rather than "cannot tell".
    function earned(
        address,
        NftPosition calldata position,
        address[] memory
    ) external view returns (uint256[] memory) {
        uint256[] memory rewardAmounts = new uint256[](1);
        rewardAmounts[0] = IHybraClGauge(position.farm.stakingContract)
            .earned(position.tokenId);
        return rewardAmounts;
    }

    /// @dev Token-level: the gauge publishes nothing tying a tokenId to its
    /// depositor, so this cannot be bound to `user` without a getter from
    /// Hybra. `balanceOf(uint256)` is the position's liquidity, not its
    /// custody. Callers relying on this for custody are backstopped by the
    /// gauge, which rejects a withdraw from a non-depositor.
    function isStaked(
        address,
        NftPosition calldata position
    ) external view returns (bool) {
        uint256 balance = IHybraClGauge(position.farm.stakingContract)
            .balanceOf(position.tokenId);
        return balance > 0 ? true : false;
    }
}
