// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";
import { SwapStep } from "contracts/dex/SwapTypes.sol";
import {
    ICurveStableNgSwapFactory,
    ICurveStableNgSwapPool
} from "contracts/interfaces/external/curve/ICurveStableNgSwap.sol";

/// @notice Swaps through Curve StableSwap-NG pools. `step.router` is the
/// allowlisted NG factory and `step.dexData` is `abi.encode(pool)`. The coin
/// indices come from the factory's registry, which also binds the pool to the
/// factory: a pool the factory did not deploy has no coins there.
/// @dev Factory authorization trusts the selected deployment and its admin,
/// including their control of pool implementations. Curve-compatible source
/// alone does not establish operator identity. Deployment plans record the
/// provenance of separately operated factories such as Spectra.
contract CurveStableNgPoolAdapter is DexAdapterBase {
    error InvalidTokens();

    constructor(
        address admin_,
        address allowlist_
    ) DexAdapterBase(admin_, allowlist_) { }

    function version() external pure override returns (uint16) {
        return 2;
    }

    function _swap(
        SwapStep calldata step,
        uint256 amountIn
    ) internal override returns (uint256) {
        allowlist.requireAllowedFactory(step.router);
        // Reads the first word only, so the legacy `(pool, i, j)` encoding
        // also decodes; the indices are always derived below.
        address pool = abi.decode(step.dexData, (address));
        address[] memory coins =
            ICurveStableNgSwapFactory(step.router).get_coins(pool);

        uint256 n = coins.length;
        uint256 i = n;
        uint256 j = n;
        for (uint256 k; k < n; k++) {
            if (coins[k] == step.tokenIn) i = k;
            else if (coins[k] == step.tokenOut) j = k;
        }
        if (i == n || j == n) revert InvalidTokens();

        _swapViaRouter(
            step.tokenIn,
            amountIn,
            pool,
            abi.encodeCall(
                ICurveStableNgSwapPool.exchange,
                (int128(int256(i)), int128(int256(j)), amountIn, 0, msg.sender)
            )
        );
        return 0;
    }
}
