// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";
import {
    IWormholeCircleIntegration
} from "contracts/bridges/interfaces/IWormholeCircleIntegration.sol";
import {
    BridgeDepositStrategy
} from "contracts/strategies/BridgeDepositStrategy.sol";

/// @title WormholeCctpDepositAdapter
/// @notice Redeems Wormhole Circle Integration transfers and deposits native
/// USDC into a farm position via BridgeDepositStrategy.
/// @dev Uses the same permissionless relay model as the Wormhole token bridge
/// adapters. Wormhole's Circle Integration contract verifies the paired
/// Wormhole and Circle messages, enforces replay protection, and requires this
/// adapter to be the encoded mint recipient before USDC is minted here.
contract WormholeCctpDepositAdapter is BridgeAdapterBase {
    BridgeDepositStrategy public immutable strategy;
    IWormholeCircleIntegration public immutable circleIntegration;

    constructor(
        address strategy_,
        address circleIntegration_,
        address admin_,
        address guardian_
    ) BridgeAdapterBase(admin_, guardian_) {
        strategy = BridgeDepositStrategy(strategy_);
        circleIntegration = IWormholeCircleIntegration(circleIntegration_);
    }

    /// @notice Redeem a Wormhole CCTP transfer-with-payload and deposit into a
    /// farm position.
    /// @param redeemParams Wormhole message plus paired Circle message and
    /// attestation.
    function redeemTokensWithPayload(
        IWormholeCircleIntegration.RedeemParameters calldata redeemParams
    ) external payable {
        IWormholeCircleIntegration.DepositWithPayload memory deposit =
            circleIntegration.redeemTokensWithPayload(redeemParams);

        (
            address sickleOwner,
            BridgeDepositStrategy.DepositParams memory params,
            bytes32 intentId,
            uint256 deadline,
            bytes memory signature
        ) = abi.decode(
            deposit.payload,
            (
                address,
                BridgeDepositStrategy.DepositParams,
                bytes32,
                uint256,
                bytes
            )
        );

        address localToken = address(uint160(uint256(deposit.token)));
        if (msg.value > 0) {
            SafeTransferLib.safeTransferETH(sickleOwner, msg.value);
        }
        SafeTransferLib.safeTransfer(
            localToken, address(strategy), deposit.amount
        );
        strategy.executeDeposit(
            localToken,
            deposit.amount,
            sickleOwner,
            params,
            intentId,
            deadline,
            signature
        );
    }
}
