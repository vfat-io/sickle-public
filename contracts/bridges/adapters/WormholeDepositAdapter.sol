// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { WormholeAdapterBase } from "./WormholeAdapterBase.sol";
import {
    BridgeDepositStrategy
} from "contracts/strategies/BridgeDepositStrategy.sol";

/// @title WormholeDepositAdapter
/// @notice Redeems Wormhole Token Bridge transfer-with-payload VAAs and
/// deposits into a farm position via BridgeDepositStrategy.
/// @dev Uses the Executor Relay pattern: `executeVAAv1()` is callable by
/// anyone (permissionless relay). Security relies on guardian-signed VAA
/// verification, Token Bridge replay protection, balance-before/after
/// isolation, and the downstream EIP-712 signature check in
/// BridgeDepositStrategy.
contract WormholeDepositAdapter is WormholeAdapterBase {
    BridgeDepositStrategy public immutable strategy;

    constructor(
        address strategy_,
        address tokenBridge_,
        address admin_,
        address guardian_
    ) WormholeAdapterBase(tokenBridge_, admin_, guardian_) {
        strategy = BridgeDepositStrategy(strategy_);
    }

    /// @notice Redeem a Wormhole transfer-with-payload VAA and deposit into
    /// a farm position.
    /// @param encodedVAA Signed Wormhole VAA (Token Bridge type 3 transfer
    /// whose `to` field is this adapter's address)
    function executeVAAv1(
        bytes calldata encodedVAA
    ) external payable {
        (address localToken, uint256 received, bytes memory transferMsg,,) =
            _redeemTransfer(encodedVAA);

        // `_redeemTransfer` already returns the decoded application payload.
        (
            address sickleOwner,
            BridgeDepositStrategy.DepositParams memory params,
            bytes32 intentId,
            uint256 deadline,
            bytes memory signature
        ) = abi.decode(
            transferMsg,
            (
                address,
                BridgeDepositStrategy.DepositParams,
                bytes32,
                uint256,
                bytes
            )
        );

        if (msg.value > 0) {
            SafeTransferLib.safeTransferETH(sickleOwner, msg.value);
        }

        SafeTransferLib.safeTransfer(localToken, address(strategy), received);
        strategy.executeDeposit(
            localToken,
            received,
            sickleOwner,
            params,
            intentId,
            deadline,
            signature
        );
    }
}
