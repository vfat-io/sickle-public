// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { GuardianAdmin } from "contracts/base/GuardianAdmin.sol";
import {
    StrategyModule,
    SickleFactory,
    Sickle,
    ConnectorRegistry
} from "contracts/modules/StrategyModule.sol";
import { IBinFarmConnector } from "contracts/interfaces/IBinFarmConnector.sol";
import { IBinZapLib } from "contracts/interfaces/libraries/IBinZapLib.sol";
import { IBridgeLib } from "contracts/interfaces/libraries/IBridgeLib.sol";
import { IFeesLib } from "contracts/interfaces/libraries/IFeesLib.sol";
import { ISwapLib } from "contracts/interfaces/libraries/ISwapLib.sol";
import { ITransferLib } from "contracts/interfaces/libraries/ITransferLib.sol";
import { BinSettingsRegistry } from "contracts/BinSettingsRegistry.sol";
import { BinKey, BinSettings } from "contracts/structs/BinSettingsStructs.sol";
import {
    BinDeposit,
    BinHarvest,
    BinPosition,
    BinWithdraw,
    BinZapIn
} from "contracts/structs/BinFarmStrategyStructs.sol";

library BinBridgeStrategyFees {
    bytes4 constant Deposit = bytes4(keccak256("BridgeDepositFee"));
    bytes4 constant Withdraw = bytes4(keccak256("BridgeWithdrawFee"));
    bytes4 constant Harvest = bytes4(keccak256("BridgeWithdrawHarvestFee"));
}

/// @notice Bridges an owner's bin position out, or deposits bridge tokens
/// already delivered to the owner's Sickle. The signed deposit path lets a
/// keeper execute delivery from a bridge without an execution callback.
contract BinBridgeStrategy is StrategyModule, GuardianAdmin, EIP712 {
    error InvalidParameters();
    error ArrayLengthMismatch();
    error InvalidIntentSignature();
    error AmountBelowMinimum();
    error InsufficientDeliveredBalance();
    error ZeroSwapAmountNotAllowed();
    error ZeroLiquidityAmountNotAllowed();
    error PausedError();

    event PausedSet(bool paused);

    bool public paused;

    enum DepositMode {
        Deposit,
        Increase
    }

    struct Libraries {
        IBinZapLib binZapLib;
        ISwapLib swapLib;
        IFeesLib feesLib;
        ITransferLib transferLib;
        IBridgeLib bridgeLib;
    }

    struct DepositParams {
        DepositMode mode;
        uint256 minAmount;
        BinDeposit deposit;
        BinSettings settings;
        uint256[] expectedBinIds;
        address[] sweepTokens;
    }

    struct BridgeParams {
        address bridgeContract;
        bytes bridgeCalldata;
        address bridgeToken;
        uint256 bridgeAmount;
    }

    bytes32 public constant SICKLE_DEPOSIT_TYPEHASH = keccak256(
        "SickleBinBridgeDeposit(address owner,address token,uint256 amount,bytes32 paramsHash,bytes32 intentId,uint256 deadline)"
    );

    IBinZapLib public immutable binZapLib;
    ISwapLib public immutable swapLib;
    IFeesLib public immutable feesLib;
    ITransferLib public immutable transferLib;
    IBridgeLib public immutable bridgeLib;
    BinSettingsRegistry public immutable binSettingsRegistry;

    mapping(address => mapping(bytes32 => bool)) public usedIntentIds;

    event BinBridgeDeposited(
        Sickle indexed sickle,
        address indexed pair,
        address indexed stakingContract,
        address token,
        uint256 amount,
        uint256[] ids,
        uint256[] mintedAmounts
    );

    constructor(
        SickleFactory factory_,
        ConnectorRegistry connectorRegistry_,
        BinSettingsRegistry binSettingsRegistry_,
        Libraries memory libraries_,
        address admin_,
        address guardian_
    )
        StrategyModule(factory_, connectorRegistry_)
        GuardianAdmin(admin_, guardian_)
        EIP712("BinBridgeStrategy", "1")
    {
        binSettingsRegistry = binSettingsRegistry_;
        binZapLib = libraries_.binZapLib;
        swapLib = libraries_.swapLib;
        feesLib = libraries_.feesLib;
        transferLib = libraries_.transferLib;
        bridgeLib = libraries_.bridgeLib;
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function pause() external onlyGuardianOrAdmin {
        if (paused) return;
        paused = true;
        emit PausedSet(true);
    }

    function unpause() external onlyAdmin {
        if (!paused) return;
        paused = false;
        emit PausedSet(false);
    }

    /// @notice Owner executes a deposit after a bridge delivered tokens to
    /// their Sickle. The deposit's tokensIn/amountsIn must be empty.
    function depositFromSickle(
        address token,
        uint256 amount,
        DepositParams calldata params
    ) external {
        _requireNotPaused();
        _depositFromSickle(msg.sender, token, amount, params);
    }

    /// @notice Any keeper can execute a signed deposit after delivery to the
    /// owner's Sickle. The exact amount, params, intent ID, and deadline are
    /// signed; an intent ID can succeed only once.
    function depositFromSickleWithSignature(
        address owner,
        address token,
        uint256 amount,
        DepositParams calldata params,
        bytes32 intentId,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _requireNotPaused();
        if (
            block.timestamp > deadline || usedIntentIds[owner][intentId]
                || !_validSignature(
                    owner, token, amount, params, intentId, deadline, signature
                )
        ) revert InvalidIntentSignature();
        usedIntentIds[owner][intentId] = true;
        _depositFromSickle(owner, token, amount, params);
    }

    function _requireNotPaused() private view {
        if (paused) revert PausedError();
    }

    /// @notice Withdraw some bin shares, zap out, then bridge an exact token
    /// amount. Remaining tokens are swept to the owner.
    function decreaseAndBridge(
        BinPosition calldata position,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        BinWithdraw calldata withdrawParams,
        BridgeParams calldata bridgeParams,
        address[] calldata sweepTokens
    ) external payable {
        Sickle sickle = getSickle(msg.sender);
        _withdraw(sickle, position, ids, amounts, withdrawParams);
        _bridgeAndSweep(sickle, bridgeParams, sweepTokens);
        _syncSettings(sickle, position);
    }

    /// @notice Claim farm rewards, withdraw bin shares, then bridge an exact
    /// token amount. A full exit supplies all held/staked share amounts.
    function exitAndBridge(
        BinPosition calldata position,
        BinHarvest calldata harvestParams,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        BinWithdraw calldata withdrawParams,
        BridgeParams calldata bridgeParams,
        address[] calldata sweepTokens
    ) external payable {
        Sickle sickle = getSickle(msg.sender);
        _harvest(sickle, position, harvestParams);
        _withdraw(sickle, position, ids, amounts, withdrawParams);
        _bridgeAndSweep(sickle, bridgeParams, sweepTokens);
        _syncSettings(sickle, position);
    }

    /// @notice Claim farm rewards and bridge the selected token without
    /// withdrawing bin shares.
    function harvestAndBridge(
        BinPosition calldata position,
        BinHarvest calldata harvestParams,
        BridgeParams calldata bridgeParams,
        address[] calldata sweepTokens
    ) external payable {
        Sickle sickle = getSickle(msg.sender);
        _harvest(sickle, position, harvestParams);
        _bridgeAndSweep(sickle, bridgeParams, sweepTokens);
    }

    function _validSignature(
        address owner,
        address token,
        uint256 amount,
        DepositParams calldata params,
        bytes32 intentId,
        uint256 deadline,
        bytes calldata signature
    ) private view returns (bool) {
        bytes32 structHash = keccak256(
            abi.encode(
                SICKLE_DEPOSIT_TYPEHASH,
                owner,
                token,
                amount,
                keccak256(abi.encode(params)),
                intentId,
                deadline
            )
        );
        (address recovered, ECDSA.RecoverError error) =
            ECDSA.tryRecover(_hashTypedDataV4(structHash), signature);
        return error == ECDSA.RecoverError.NoError && recovered == owner;
    }

    function _depositFromSickle(
        address owner,
        address token,
        uint256 amount,
        DepositParams calldata params
    ) private {
        if (amount == 0 || amount < params.minAmount) {
            revert AmountBelowMinimum();
        }
        if (
            params.deposit.increase.tokensIn.length != 0
                || params.deposit.increase.amountsIn.length != 0
                || address(params.deposit.lbPair)
                    != address(
                        params.deposit.increase.zap.addLiquidityParams.lbPair
                    )
        ) revert InvalidParameters();

        BinZapIn calldata zap = params.deposit.increase.zap;
        for (uint256 i; i < zap.swaps.length; ++i) {
            if (zap.swaps[i].amountIn == 0) revert ZeroSwapAmountNotAllowed();
        }
        if (
            zap.addLiquidityParams.amountX == 0
                && zap.addLiquidityParams.amountY == 0
        ) revert ZeroLiquidityAmountNotAllowed();

        Sickle sickle = getOrDeploySickle(owner, address(0), bytes32(0));
        if (IERC20(token).balanceOf(address(sickle)) < amount) {
            revert InsufficientDeliveredBalance();
        }
        _call(
            sickle,
            address(feesLib),
            abi.encodeCall(
                IFeesLib.chargeFee,
                (address(this), BinBridgeStrategyFees.Deposit, token, amount)
            )
        );

        (uint256[] memory ids, uint256[] memory minted) =
            _zapInAndGetMinted(sickle, zap, params.expectedBinIds);
        BinPosition memory position = BinPosition({
            farm: params.deposit.farm, lbPair: params.deposit.lbPair
        });
        if (position.farm.stakingContract != address(0)) {
            _call(
                sickle,
                connectorRegistry.connectorOf(position.farm.stakingContract),
                abi.encodeCall(
                    IBinFarmConnector.deposit,
                    (position, ids, minted, params.deposit.increase.extraData)
                )
            );
        }

        BinKey memory key = BinKey({
            sickle: sickle,
            lbPair: position.lbPair,
            stakingContract: position.farm.stakingContract,
            poolIndex: position.farm.poolIndex
        });
        if (params.mode == DepositMode.Deposit) {
            binSettingsRegistry.setAfterMint(key, params.settings, ids, minted);
        } else {
            binSettingsRegistry.includeAfterOwnerMint(key, ids, minted);
        }
        _sweep(sickle, params.sweepTokens);
        emit BinBridgeDeposited(
            sickle,
            address(position.lbPair),
            position.farm.stakingContract,
            token,
            amount,
            ids,
            minted
        );
    }

    function _zapInAndGetMinted(
        Sickle sickle,
        BinZapIn calldata zap,
        uint256[] calldata expectedBinIds
    ) private returns (uint256[] memory ids, uint256[] memory minted) {
        if (zap.swaps.length > 0) {
            _call(
                sickle,
                address(swapLib),
                abi.encodeCall(ISwapLib.swapMultiple, (zap.swaps))
            );
        }
        ids = _idsAtActiveId(
            zap.addLiquidityParams.lbPair.getActiveId(),
            zap.addLiquidityParams.deltaIds
        );
        uint256[] memory balances = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            balances[i] = zap.addLiquidityParams.lbPair
            .balanceOf(address(sickle), ids[i]);
        }
        _call(
            sickle,
            address(binZapLib),
            abi.encodeCall(
                IBinZapLib.addLiquidityChecked,
                (zap.addLiquidityParams, expectedBinIds)
            )
        );
        minted = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            minted[i] = zap.addLiquidityParams.lbPair
            .balanceOf(address(sickle), ids[i]) - balances[i];
        }
    }

    function _idsAtActiveId(
        uint256 activeId,
        int256[] calldata deltaIds
    ) private pure returns (uint256[] memory ids) {
        ids = new uint256[](deltaIds.length);
        for (uint256 i; i < deltaIds.length; ++i) {
            int256 id = int256(activeId) + deltaIds[i];
            if (id < 0 || id > int256(uint256(type(uint24).max))) {
                revert InvalidParameters();
            }
            ids[i] = uint256(id);
        }
    }

    function _harvest(
        Sickle sickle,
        BinPosition calldata position,
        BinHarvest calldata params
    ) private {
        if (position.farm.stakingContract == address(0)) return;
        _call(
            sickle,
            connectorRegistry.connectorOf(position.farm.stakingContract),
            abi.encodeCall(
                IBinFarmConnector.claim, (position, params.harvest.extraData)
            )
        );
        if (params.swaps.length > 0) {
            _call(
                sickle,
                address(swapLib),
                abi.encodeCall(ISwapLib.swapMultiple, (params.swaps))
            );
        }
        _call(
            sickle,
            address(feesLib),
            abi.encodeCall(
                IFeesLib.chargeFees,
                (
                    address(this),
                    BinBridgeStrategyFees.Harvest,
                    params.swaps.length > 0
                        ? params.outputTokens
                        : params.harvest.rewardTokens
                )
            )
        );
        _sweep(sickle, params.sweepTokens);
    }

    function _withdraw(
        Sickle sickle,
        BinPosition calldata position,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        BinWithdraw calldata params
    ) private {
        if (ids.length != amounts.length) revert ArrayLengthMismatch();
        if (
            address(position.lbPair)
                    != address(params.zap.removeLiquidityParams.lbPair)
                || keccak256(abi.encode(ids, amounts))
                    != keccak256(
                        abi.encode(
                            params.zap.removeLiquidityParams.ids,
                            params.zap.removeLiquidityParams.amounts
                        )
                    )
        ) revert InvalidParameters();
        if (position.farm.stakingContract != address(0)) {
            _call(
                sickle,
                connectorRegistry.connectorOf(position.farm.stakingContract),
                abi.encodeCall(
                    IBinFarmConnector.withdraw,
                    (position, ids, amounts, params.extraData)
                )
            );
        }
        _call(
            sickle,
            address(binZapLib),
            abi.encodeCall(IBinZapLib.zapOut, (params.zap))
        );
        if (params.zap.swaps.length > 0) {
            _call(
                sickle,
                address(feesLib),
                abi.encodeCall(
                    IFeesLib.chargeFees,
                    (
                        address(this),
                        BinBridgeStrategyFees.Withdraw,
                        params.tokensOut
                    )
                )
            );
        }
    }

    function _bridgeAndSweep(
        Sickle sickle,
        BridgeParams calldata params,
        address[] calldata sweepTokens
    ) private {
        uint256 len = sweepTokens.length > 0 ? 2 : 1;
        address[] memory targets = new address[](len);
        bytes[] memory data = new bytes[](len);
        targets[0] = address(bridgeLib);
        data[0] = abi.encodeCall(
            IBridgeLib.bridge,
            (
                params.bridgeContract,
                params.bridgeCalldata,
                params.bridgeToken,
                params.bridgeAmount
            )
        );
        if (sweepTokens.length > 0) {
            targets[1] = address(transferLib);
            data[1] = abi.encodeCall(
                ITransferLib.transferTokensToUser, (sweepTokens)
            );
        }
        sickle.multicall{ value: msg.value }(targets, data);
    }

    function _syncSettings(
        Sickle sickle,
        BinPosition calldata position
    ) private {
        binSettingsRegistry.syncAfterOwnerWithdrawal(
            BinKey({
                sickle: sickle,
                lbPair: position.lbPair,
                stakingContract: position.farm.stakingContract,
                poolIndex: position.farm.poolIndex
            })
        );
    }

    function _sweep(
        Sickle sickle,
        address[] calldata tokens
    ) private {
        if (tokens.length == 0) return;
        _call(
            sickle,
            address(transferLib),
            abi.encodeCall(ITransferLib.transferTokensToUser, (tokens))
        );
    }

    function _call(
        Sickle sickle,
        address target,
        bytes memory callData
    ) private {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = target;
        data[0] = callData;
        sickle.multicall(targets, data);
    }
}
