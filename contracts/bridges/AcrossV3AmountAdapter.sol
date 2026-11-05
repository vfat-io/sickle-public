// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { GuardianAdmin } from "contracts/base/GuardianAdmin.sol";
import {
    IBridgeAmountAdapter
} from "contracts/interfaces/IBridgeAmountAdapter.sol";
import {
    IAcrossV3SpokePool
} from "contracts/interfaces/external/across/IAcrossV3SpokePool.sol";

/// @title AcrossV3AmountAdapter
/// @notice Source-side Across V3 adapter for exact-amount bridge routes.
/// @dev Computes `depositV3.outputAmount` from the actual token amount pulled
/// from the caller using an off-chain quoted fixed fee plus variable fee
/// percentage.
contract AcrossV3AmountAdapter is GuardianAdmin, IBridgeAmountAdapter {
    uint256 public constant WAD = 1e18;

    error ZeroAddress();
    error NativeBridgeTokenUnsupported();
    error UnexpectedNativeValue(uint256 supplied);
    error PausedError();
    error FeePctTooHigh();
    error AmountBelowMinimum(uint256 amount, uint256 minimum);
    error AmountAboveMaximum(uint256 amount, uint256 maximum);
    error OutputAmountTooLow(uint256 outputAmount, uint256 minimum);
    error FeeExceedsAmount(uint256 fee, uint256 amount);
    error ZeroAmountReceived();
    error InvalidDestinationChainId();
    error FillDeadlineExpired(uint32 fillDeadline);

    event PausedSet(bool paused);
    event TokensRescued(
        address indexed token, address indexed to, uint256 amount
    );
    event ETHRescued(address indexed to, uint256 amount);

    event AcrossV3ExactAmountBridge(
        address indexed caller,
        address indexed bridgeToken,
        address indexed recipient,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId
    );

    struct FeeModel {
        /// @notice Fixed fee in input-token units, normally
        /// suggested-fees.relayerGasFee.total.
        uint256 fixedFee;
        /// @notice Variable fee percentage in 1e18 precision. Normally the
        /// non-gas fee pcts from the Across quote, or totalRelayFee.pct with
        /// fixedFee set to zero.
        uint256 variableFeePct;
        /// @notice Minimum acceptable Across outputAmount for this bridge leg.
        uint256 minOutputAmount;
        /// @notice Lower bound for the runtime input amount. Use zero for no
        /// lower bound.
        uint256 minInputAmount;
        /// @notice Upper bound for the runtime input amount. Use
        /// type(uint256).max for no upper bound.
        uint256 maxInputAmount;
    }

    struct DepositParams {
        address depositor;
        address recipient;
        address outputToken;
        uint256 destinationChainId;
        address exclusiveRelayer;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
        bytes message;
        FeeModel feeModel;
    }

    IAcrossV3SpokePool public immutable spokePool;
    bool public paused;

    constructor(
        address spokePool_,
        address admin_,
        address guardian_
    ) GuardianAdmin(admin_, guardian_) {
        if (spokePool_ == address(0)) revert ZeroAddress();
        spokePool = IAcrossV3SpokePool(spokePool_);
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

    function bridgeExactAmount(
        address bridgeToken,
        uint256 amount,
        bytes calldata params
    ) external payable override returns (bytes memory result) {
        if (paused) revert PausedError();
        if (msg.value != 0) revert UnexpectedNativeValue(msg.value);
        if (bridgeToken == address(0)) revert NativeBridgeTokenUnsupported();

        DepositParams memory decoded = abi.decode(params, (DepositParams));
        _validateDepositParams(decoded);

        uint256 received = _pullExactAvailable(bridgeToken, amount);
        uint256 outputAmount = _outputAmount(received, decoded.feeModel);

        SafeTransferLib.safeApprove(bridgeToken, address(spokePool), 0);
        SafeTransferLib.safeApprove(bridgeToken, address(spokePool), received);

        spokePool.depositV3(
            decoded.depositor,
            decoded.recipient,
            bridgeToken,
            decoded.outputToken,
            received,
            outputAmount,
            decoded.destinationChainId,
            decoded.exclusiveRelayer,
            decoded.quoteTimestamp,
            decoded.fillDeadline,
            decoded.exclusivityDeadline,
            decoded.message
        );

        SafeTransferLib.safeApprove(bridgeToken, address(spokePool), 0);

        emit AcrossV3ExactAmountBridge(
            msg.sender,
            bridgeToken,
            decoded.recipient,
            received,
            outputAmount,
            decoded.destinationChainId
        );

        return abi.encode(received, outputAmount);
    }

    function quoteOutputAmount(
        uint256 amount,
        FeeModel calldata feeModel
    ) external pure returns (uint256) {
        return _outputAmount(amount, feeModel);
    }

    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyAdmin {
        SafeTransferLib.safeTransfer(token, to, amount);
        emit TokensRescued(token, to, amount);
    }

    function rescueETH(
        address to
    ) external onlyAdmin {
        uint256 amount = address(this).balance;
        SafeTransferLib.safeTransferETH(to, amount);
        emit ETHRescued(to, amount);
    }

    function _validateDepositParams(
        DepositParams memory params
    ) internal view {
        if (
            params.depositor == address(0) || params.recipient == address(0)
                || params.outputToken == address(0)
        ) {
            revert ZeroAddress();
        }
        if (params.destinationChainId == 0) revert InvalidDestinationChainId();
        if (params.fillDeadline <= block.timestamp) {
            revert FillDeadlineExpired(params.fillDeadline);
        }
    }

    function _pullExactAvailable(
        address bridgeToken,
        uint256 amount
    ) internal returns (uint256 received) {
        uint256 balanceBefore = IERC20(bridgeToken).balanceOf(address(this));
        SafeTransferLib.safeTransferFrom(
            bridgeToken, msg.sender, address(this), amount
        );
        received = IERC20(bridgeToken).balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert ZeroAmountReceived();
    }

    function _outputAmount(
        uint256 amount,
        FeeModel memory feeModel
    ) internal pure returns (uint256 outputAmount) {
        if (feeModel.variableFeePct > WAD) revert FeePctTooHigh();
        if (amount < feeModel.minInputAmount) {
            revert AmountBelowMinimum(amount, feeModel.minInputAmount);
        }
        if (amount > feeModel.maxInputAmount) {
            revert AmountAboveMaximum(amount, feeModel.maxInputAmount);
        }

        uint256 variableFee = (amount * feeModel.variableFeePct) / WAD;
        uint256 totalFee = feeModel.fixedFee + variableFee;
        if (totalFee >= amount) revert FeeExceedsAmount(totalFee, amount);

        outputAmount = amount - totalFee;
        if (outputAmount < feeModel.minOutputAmount) {
            revert OutputAmountTooLow(outputAmount, feeModel.minOutputAmount);
        }
    }
}
