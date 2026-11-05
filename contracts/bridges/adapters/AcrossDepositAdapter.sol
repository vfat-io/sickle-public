// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";
import {
    BridgeDepositStrategy
} from "contracts/strategies/BridgeDepositStrategy.sol";
import {
    IAcrossMessageHandler
} from "contracts/bridges/interfaces/IAcrossMessageHandler.sol";

/// @title AcrossDepositAdapter
/// @notice Across destination adapter. Routes to
/// `BridgeDepositStrategy.executeDepositStrict`, so an under-funded fill
/// reverts rather than quietly degrading to a token delivery.
///
/// @dev Across relayers size a messaged fill with `eth_estimateGas`, which
/// binary-searches for the smallest gas at which the transaction *succeeds*.
/// `executeDeposit`'s graceful fallback makes an under-funded call succeed, so
/// the estimate can converge on the fallback path and the farm entry is never
/// funded.
///
/// Measured live 2026-08-18, four Ink<->Soneium legs through four different
/// relayers. Destination requirement was stable at 1.02-1.07M gas throughout;
/// what varied was the grant:
///   Soneium-destination  1.37x and 1.47x of need  -> landed a real stake
///   Ink-destination      0.92x and 0.96x of need  -> fell back, tokens to owner
/// Both starved grants sat at fallback-path cost x ~1.12, from two independent
/// relayers -- the estimator pricing the path that completes. The generous
/// relayers apply a floor the starved ones do not.
///
/// So the failure is not a property of the deposit (a COLD destination landed
/// fine on a generous relayer); it is a property of whichever relayer picks the
/// fill up. That makes it a lottery the depositor cannot influence or detect,
/// which is the argument for removing the cheap success entirely rather than
/// tuning around it.
///
/// Safe because `SpokePool._transferTokensToRecipient` invokes the handler
/// with no try/catch and no gas cap: a revert here reverts the whole fill, so
/// no tokens are delivered and the depositor is refunded on the origin chain
/// after `fillDeadline`. Nothing is left stranded on the destination.
///
/// This behaviour is correct only for bridges that revert the delivery when
/// the handler reverts, which is why it lives here and not in a shared base.
/// Stargate is the counter-example: `StargateAdapterBase.lzCompose` consumes
/// the compose guid *before* its caught inner call, so reverting there parks
/// the tokens on the adapter awaiting an admin rescue.
contract AcrossDepositAdapter is BridgeAdapterBase, IAcrossMessageHandler {
    BridgeDepositStrategy public immutable strategy;

    constructor(
        address strategy_,
        address admin_,
        address guardian_
    ) BridgeAdapterBase(admin_, guardian_) {
        strategy = BridgeDepositStrategy(strategy_);
    }

    function handleV3AcrossMessage(
        address tokenSent,
        uint256 amount,
        address, // relayer
        bytes memory message
    ) external override {
        _onlyWhitelistedEndpoint();
        (
            address sickleOwner,
            BridgeDepositStrategy.DepositParams memory params,
            bytes32 intentId,
            uint256 deadline,
            bytes memory signature
        ) = abi.decode(
            message,
            (
                address,
                BridgeDepositStrategy.DepositParams,
                bytes32,
                uint256,
                bytes
            )
        );
        uint256 forwarded =
            _forwardAvailable(tokenSent, address(strategy), amount);
        strategy.executeDepositStrict(
            tokenSent, forwarded, sickleOwner, params, intentId, deadline,
            signature
        );
    }
}
