// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SwapStep, DexType } from "contracts/dex/SwapTypes.sol";
import { DexAdapterBase } from "contracts/dex/DexAdapterBase.sol";
import {
    IAeroTokenMigration
} from "contracts/interfaces/external/aero/IAeroTokenMigration.sol";

/// @notice One-way, exact 1:1 liquid AERO upgrade through the official Base
/// converter. The caller owns all balances, approvals and conversion proceeds.
/// @dev No custody or router back-pointer. The existing SwapRouter gates the
/// converter through RouterAllowlist and authorizes callbacks only during this
/// adapter's dispatch. Its net-output minimum/deadline remain authoritative.
contract AeroTokenMigrationAdapter is DexAdapterBase {
    address public constant CONVERTER =
        0x22a2F7340a3fB4C7C389D91eE954766B12476721;
    address public constant V2_TOKEN =
        0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address public constant V3_TOKEN =
        0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;

    error InvalidMigration();
    error InvalidConversion();
    error InvalidDexData();
    error IncorrectConversionOutput();

    constructor(
        address admin_,
        address allowlist_
    ) DexAdapterBase(admin_, allowlist_) {
        if (
            CONVERTER.code.length == 0 || V2_TOKEN.code.length == 0
                || V3_TOKEN.code.length == 0
        ) revert InvalidMigration();
        if (
            IAeroTokenMigration(CONVERTER).V2_TOKEN() != V2_TOKEN
                || IAeroTokenMigration(CONVERTER).V3_TOKEN() != V3_TOKEN
        ) revert InvalidMigration();
    }

    function version() external pure override returns (uint16) {
        return 1;
    }

    function _swap(
        SwapStep calldata step,
        uint256 amountIn
    ) internal override returns (uint256) {
        if (
            step.dexType != uint8(DexType.AeroTokenMigration)
                || step.router != CONVERTER || step.tokenIn != V2_TOKEN
                || step.tokenOut != V3_TOKEN || amountIn == 0 || msg.value != 0
        ) revert InvalidConversion();
        if (step.dexData.length != 0) revert InvalidDexData();
        uint256 beforeBalance = IERC20(V3_TOKEN).balanceOf(msg.sender);
        _adapterApprove(V2_TOKEN, CONVERTER, amountIn);
        _adapterCall(
            CONVERTER,
            0,
            abi.encodeCall(
                IAeroTokenMigration.depositLiquid, (amountIn, msg.sender)
            )
        );
        _adapterApprove(V2_TOKEN, CONVERTER, 0);
        uint256 afterBalance = IERC20(V3_TOKEN).balanceOf(msg.sender);
        if (
            afterBalance < beforeBalance
                || afterBalance - beforeBalance != amountIn
        ) revert IncorrectConversionOutput();
        return amountIn;
    }
}
