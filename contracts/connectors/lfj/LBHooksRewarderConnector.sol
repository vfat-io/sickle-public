// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IBinFarmConnector } from "contracts/interfaces/IBinFarmConnector.sol";
import { BinPosition } from "contracts/structs/BinFarmStrategyStructs.sol";
import {
    ILBHooksRewarder,
    ILBPairHooks
} from "contracts/interfaces/external/lfj/ILBHooksRewarder.sol";

/// @notice LFJ and Pharaoh hook rewards accrue while shares remain in the pair.
/// The deposit and withdraw hooks validate the rewarder but do not transfer LP
/// shares. All external calls are made by the Sickle through delegatecall.
contract LBHooksRewarderConnector is IBinFarmConnector {
    error InvalidRewarder();
    error UnsupportedRewardQuery();

    function _rewarder(
        BinPosition calldata position
    ) private view returns (ILBHooksRewarder rewarder) {
        rewarder = ILBHooksRewarder(position.farm.stakingContract);
        if (rewarder.getLBPair() != address(position.lbPair)) {
            revert InvalidRewarder();
        }
    }

    function _isActive(
        BinPosition calldata position,
        ILBHooksRewarder rewarder
    ) private view returns (bool) {
        bytes32 parameters =
            ILBPairHooks(address(position.lbPair)).getLBHooksParameters();
        return address(uint160(uint256(parameters))) == address(rewarder);
    }

    function deposit(
        BinPosition calldata position,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external view override {
        if (!_isActive(position, _rewarder(position))) {
            revert InvalidRewarder();
        }
    }

    function withdraw(
        BinPosition calldata position,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external view override {
        _rewarder(position);
    }

    /// @param extraData ABI encoded array of bin IDs whose rewards to update.
    function claim(
        BinPosition calldata position,
        bytes calldata extraData
    ) external override {
        ILBHooksRewarder rewarder = _rewarder(position);
        if (!_isActive(position, rewarder)) return;
        uint256[] memory ids = abi.decode(extraData, (uint256[]));
        rewarder.claim(address(this), ids);
    }

    function balanceOf(
        BinPosition calldata position,
        address user,
        uint256[] calldata ids
    ) external view override returns (uint256[] memory balances) {
        _rewarder(position);
        balances = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            balances[i] = position.lbPair.balanceOf(user, ids[i]);
        }
    }

    /// @dev The generic farm view has no bin IDs, so it cannot quote hook
    /// rewards. Query the rewarder with the selected IDs directly.
    function earned(
        BinPosition calldata,
        address,
        address[] calldata
    ) external pure override returns (uint256[] memory) {
        revert UnsupportedRewardQuery();
    }

    function isStaked(
        BinPosition calldata position,
        address
    ) external view override returns (bool) {
        _rewarder(position);
        return false;
    }
}
