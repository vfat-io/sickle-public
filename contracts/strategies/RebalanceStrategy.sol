// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../Sickle.sol";
import "../RebalanceRegistry.sol";
import "./modules/TransferModule.sol";
import "./modules/ZapModule.sol";
import "../interfaces/IFarmConnector.sol";
import "../interfaces/external/uniswap/IUniswapV3Pool.sol";
import "../interfaces/external/uniswap/INonfungiblePositionManager.sol";

library RebalanceStrategyFees {
    bytes4 constant HarvestFor = bytes4(keccak256("RebalanceHarvestForFee"));
    bytes4 constant RebalanceLow = bytes4(keccak256("RebalanceLowFee"));
    bytes4 constant RebalanceMid = bytes4(keccak256("RebalanceMidFee"));
    bytes4 constant RebalanceHigh = bytes4(keccak256("RebalanceHighFee"));
}

contract RebalanceStrategy is TransferModule, ZapModule, RebalanceRegistry {
    error TokenOutRequired();
    error TickWithinRange();
    error TickOutsideMaxRange();

    struct NftInfo {
        IUniswapV3Pool pool;
        INonfungiblePositionManager nftManager;
        uint256 tokenId;
    }

    struct DepositParams {
        address stakingContractAddress;
        address[] tokensIn;
        uint256[] amountsIn;
        ZapModule.ZapInData zapData;
        bytes extraData;
    }

    struct WithdrawParams {
        address stakingContractAddress;
        bytes extraData;
        ZapModule.ZapOutData zapData;
        address[] tokensOut;
    }

    struct HarvestParams {
        address stakingContractAddress;
        SwapData[] swaps;
        bytes extraData;
        address[] tokensOut;
    }

    address public immutable rebalanceStrategy;

    constructor(
        SickleFactory factory,
        FeesLib feesLib,
        address wrappedNativeAddress,
        ConnectorRegistry connectorRegistry
    ) ZapModule(factory, feesLib, wrappedNativeAddress, connectorRegistry) {
        rebalanceStrategy = address(this);
    }

    /* External functions */

    function setRebalanceConfig(
        INonfungiblePositionManager nftManager,
        uint256 tokenId,
        RebalanceConfig calldata config
    ) external {
        Sickle sickle = getSickle(msg.sender);
        RebalanceKey memory key = RebalanceKey(sickle, nftManager, tokenId);
        _set_rebalance_config(key, config);
    }

    function unsetRebalanceConfig(
        INonfungiblePositionManager nftManager,
        uint256 tokenId
    ) external {
        Sickle sickle = getSickle(msg.sender);
        RebalanceKey memory key = RebalanceKey(sickle, nftManager, tokenId);
        _unset_rebalance_config(key);
    }

    function rebalanceFor(
        address sickleAddress,
        NftInfo calldata nftInfo,
        HarvestParams calldata harvestParams,
        WithdrawParams calldata withdrawParams,
        DepositParams calldata depositParams,
        address[] memory sweepTokens
    ) external checkOwnerOrApproved(sickleAddress) {
        Sickle sickle = Sickle(payable(sickleAddress));

        if (withdrawParams.tokensOut.length == 0) {
            revert TokenOutRequired();
        }

        RebalanceConfig memory config = getRebalanceConfig(
            RebalanceKey(sickle, nftInfo.nftManager, nftInfo.tokenId)
        );

        int24 tick = _get_curent_tick(nftInfo.pool);

        if (tick >= config.tickLow && tick <= config.tickHigh) {
            revert TickWithinRange();
        }
        if (tick < config.minTickLow || tick > config.maxTickHigh) {
            revert TickOutsideMaxRange();
        }

        address[] memory targets = new address[](9);
        bytes[] memory data = new bytes[](9);

        targets[0] =
            connectorRegistry.connectorOf(harvestParams.stakingContractAddress);
        data[0] = abi.encodeCall(
            IFarmConnector.claim,
            (harvestParams.stakingContractAddress, harvestParams.extraData)
        );

        targets[1] = address(this);
        data[1] = abi.encodeCall(
            this._sickle_charge_fees,
            (
                address(this),
                RebalanceStrategyFees.HarvestFor,
                harvestParams.tokensOut
            )
        );

        targets[2] =
            connectorRegistry.connectorOf(withdrawParams.stakingContractAddress);
        data[2] = abi.encodeCall(
            IFarmConnector.withdraw,
            (
                withdrawParams.stakingContractAddress,
                withdrawParams.zapData.removeLiquidityData.lpAmountIn,
                withdrawParams.extraData
            )
        );

        targets[3] = address(this);
        data[3] =
            abi.encodeCall(ZapModule._sickle_zap_out, (withdrawParams.zapData));

        targets[4] = address(this);
        data[4] = abi.encodeCall(
            this._sickle_charge_fees,
            (
                address(this),
                _get_rebalance_fee(nftInfo.pool),
                withdrawParams.tokensOut
            )
        );

        targets[5] = address(this);
        data[5] =
            abi.encodeCall(ZapModule._sickle_zap_in, (depositParams.zapData));

        targets[6] = address(this);
        data[6] = abi.encodeCall(this._sickle_reset_rebalance_config, (nftInfo));

        targets[7] =
            connectorRegistry.connectorOf(depositParams.stakingContractAddress);
        data[7] = abi.encodeCall(
            IFarmConnector.deposit,
            (
                depositParams.stakingContractAddress,
                depositParams.zapData.addLiquidityData.lpToken,
                depositParams.extraData
            )
        );

        targets[8] = address(this);
        data[8] =
            abi.encodeCall(this._sickle_transfer_tokens_to_user, (sweepTokens));

        sickle.multicall(targets, data);
    }

    /* Delegate functions */

    function _sickle_reset_rebalance_config(NftInfo calldata nftInfo)
        external
        onlyRegisteredSickle
    {
        RebalanceKey memory key = RebalanceKey(
            Sickle(payable(address(this))), nftInfo.nftManager, nftInfo.tokenId
        );
        RebalanceConfig memory config =
            RebalanceStrategy(rebalanceStrategy).getRebalanceConfig(key);

        INonfungiblePositionManager nftManager =
            INonfungiblePositionManager(key.nftManager);

        uint256 newTokenId = nftManager.tokenOfOwnerByIndex(
            address(this), nftManager.balanceOf(address(this)) - 1
        );

        (,,,,, int24 tickLower, int24 tickUpper,,,,,) =
            nftManager.positions(newTokenId);

        int24 midTick = (tickUpper + tickLower) / 2;

        int24 midRange = (config.tickHigh - config.tickLow) / 2;

        config.tickLow = midTick - midRange;
        config.tickHigh = midTick + midRange;

        RebalanceKey memory newKey =
            RebalanceKey(key.sickle, key.nftManager, newTokenId);

        RebalanceStrategy(rebalanceStrategy).resetRebalanceConfig(
            key, newKey, config
        );
    }

    /* Internal functions */

    // Tick is the 2nd field in slot0, the rest can vary
    function _get_curent_tick(IUniswapV3Pool pool) internal returns (int24) {
        (, bytes memory result) =
            address(pool).call(abi.encodeCall(IUniswapV3PoolState.slot0, ()));

        int24 tick;

        assembly {
            tick := mload(add(add(result, 0x20), 32))
        }

        return tick;
    }

    function _get_rebalance_fee(IUniswapV3Pool pool)
        internal
        view
        returns (bytes4)
    {
        uint24 fee = IUniswapV3PoolImmutables(pool).fee();
        if (fee <= 500) {
            return RebalanceStrategyFees.RebalanceLow;
        } else if (fee <= 3000) {
            return RebalanceStrategyFees.RebalanceMid;
        } else {
            return RebalanceStrategyFees.RebalanceHigh;
        }
    }
}
