// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    INftFarmConnector,
    NftPosition
} from "contracts/interfaces/INftFarmConnector.sol";
import {
    ISushiStaker
} from "contracts/interfaces/external/sushi/ISushiStaker.sol";
import {
    IUniswapV3Factory
} from "contracts/interfaces/external/uniswap/IUniswapV3Factory.sol";
import {
    IDistribution
} from "contracts/interfaces/external/merkl/IDistribution.sol";
import { MerklClaimExtraData } from "contracts/structs/MerklStructs.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface ISushiswapStakerVoter {
    function gauges(
        address gauge
    )
        external
        view
        returns (bool active, uint256 created, string memory metadataURI);
}

contract SushiswapStakerConnector is INftFarmConnector {
    error NotPoolForStaking();

    ISushiswapStakerVoter public immutable sushiswapStakerVoter;
    IDistribution public immutable merklDistributor;

    constructor(
        ISushiswapStakerVoter _sushiswapStakerVoter,
        IDistribution _merklDistributor
    ) {
        sushiswapStakerVoter = _sushiswapStakerVoter;
        merklDistributor = _merklDistributor;
    }

    function depositExistingNft(
        NftPosition calldata position,
        bytes calldata // extraData
    ) external {
        (address token0, address token1, uint24 fee,,,) = ISushiStaker(
                position.farm.stakingContract
            ).getPositionInfo(position.tokenId);

        address pool = IUniswapV3Factory(
                ISushiStaker(position.farm.stakingContract).factory()
            ).getPool(token0, token1, fee);

        (bool isStakingPool,,) = sushiswapStakerVoter.gauges(pool);

        if (isStakingPool) {
            IERC721(address(position.nft))
                .approve(position.farm.stakingContract, position.tokenId);
            ISushiStaker(position.farm.stakingContract).stake(position.tokenId);
        } else {
            revert NotPoolForStaking();
        }
    }

    function withdrawNft(
        NftPosition calldata position,
        bytes calldata // extraData
    ) external {
        bool isStakedPool = ISushiStaker(position.farm.stakingContract)
            .isStaked(position.tokenId);
        if (isStakedPool) {
            ISushiStaker(position.farm.stakingContract)
                .unstake(position.tokenId);
        }
    }

    /// @notice Claims Merkl rewards. LP fees are routed by the staking
    /// contract to its own feeCollector on unstake and cannot be collected
    /// while the NFT is staked.
    function claim(
        NftPosition calldata, // position
        address[] memory, // rewardTokens
        uint128, // maxAmount0,
        uint128, // maxAmount1,
        bytes calldata extraData
    ) external {
        if (extraData.length == 0) return;

        MerklClaimExtraData memory claimExtraData =
            abi.decode(extraData, (MerklClaimExtraData));

        address[] memory users =
            new address[](claimExtraData.claimTokens.length);
        for (uint256 i; i < claimExtraData.claimTokens.length;) {
            users[i] = address(this);
            unchecked {
                i++;
            }
        }

        merklDistributor.claim(
            users,
            claimExtraData.claimTokens,
            claimExtraData.amounts,
            claimExtraData.proofs
        );
    }

    /// @dev Bound to `user`. The staker takes custody on `stake()`, so
    /// `ownerOf` reports the staker and callers fall back to this to establish
    /// control. `ISushiStaker.isStaked(tokenId)` answers only "staked by
    /// anyone", which a third party's position satisfies; `getStaker` is the
    /// staker's own record of who deposited it.
    function isStaked(
        address user,
        NftPosition calldata position
    ) external view virtual override returns (bool) {
        return ISushiStaker(position.farm.stakingContract).getStaker(
            position.tokenId
        ) == user;
    }

    function earned(
        address, // user
        NftPosition calldata, // position
        address[] memory rewardTokens
    ) external view virtual override returns (uint256[] memory) {
        return new uint256[](rewardTokens.length);
    }
}
