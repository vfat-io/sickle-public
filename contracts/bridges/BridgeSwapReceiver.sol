// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
import { SwapStep } from "contracts/dex/SwapTypes.sol";

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { GuardianAdmin } from "contracts/base/GuardianAdmin.sol";
import { SwapRouter } from "contracts/SwapRouter.sol";

interface IWETHBridgeSwapReceiver {
    function withdraw(
        uint256
    ) external;
}

/// @title BridgeSwapReceiver
/// @author vfat.tools
/// @notice Receives bridged tokens from whitelisted adapters and swaps them
/// via SwapRouter. Bridge-specific callback handling is delegated to
/// per-bridge adapter contracts (e.g. StargateSwapAdapter).
contract BridgeSwapReceiver is GuardianAdmin {
    /// ERRORS ///
    error NotWhitelistedAdapter();
    error ZeroAddress();
    error OnlySelf();
    error NativeGasDropTokenNotWrappedNative();
    error NativeGasDropExceedsAmount();
    error NativeGasDropTokenConflicts();
    error AdapterNotAContract();

    /// EVENTS ///

    event BridgeSwapExecuted(
        address indexed recipient,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    event BridgeSwapFallback(
        address indexed recipient, address token, uint256 amount
    );

    event WhitelistedAdapterSet(address adapter, bool whitelisted);

    /// STORAGE ///

    SwapRouter public immutable msr;

    mapping(address => bool) public whitelistedAdapters;
    address[] private _adapters;
    mapping(address => uint256) private _adapterIndexPlusOne;

    /// CONSTRUCTOR ///

    /// @param msr_ SwapRouter address
    /// @param admin_ Admin address for configuration
    constructor(
        address msr_,
        address admin_,
        address guardian_
    ) GuardianAdmin(admin_, guardian_) {
        if (msr_ == address(0)) revert ZeroAddress();
        msr = SwapRouter(payable(msr_));
    }

    /// PUBLIC VIEW ///

    /// @notice Enumerate the currently-allowed adapters.
    function adapters() external view returns (address[] memory) {
        return _adapters;
    }

    /// ADMIN FUNCTIONS ///

    /// @notice Whitelist or remove a bridge adapter
    /// @param adapter Bridge adapter address
    /// @param whitelisted Whether the adapter is whitelisted
    function setWhitelistedAdapter(
        address adapter,
        bool whitelisted
    ) external onlyAdmin {
        _setWhitelistedAdapter(adapter, whitelisted);
    }

    /// @notice Emergency-disable an adapter without waiting on governance.
    /// Re-enabling still requires the admin path.
    function emergencyDisableAdapter(
        address adapter
    ) external onlyGuardianOrAdmin {
        _setWhitelistedAdapter(adapter, false);
    }

    function _setWhitelistedAdapter(
        address adapter,
        bool whitelisted
    ) internal {
        // Same-chain adapters must be contracts.
        if (whitelisted && adapter.code.length == 0) {
            revert AdapterNotAContract();
        }
        bool currentlyAllowed = whitelistedAdapters[adapter];
        if (currentlyAllowed == whitelisted) return;

        whitelistedAdapters[adapter] = whitelisted;
        if (whitelisted) {
            _adapterIndexPlusOne[adapter] = _adapters.length + 1;
            _adapters.push(adapter);
        } else {
            uint256 indexPlusOne = _adapterIndexPlusOne[adapter];
            uint256 index = indexPlusOne - 1;
            uint256 lastIndex = _adapters.length - 1;
            if (index != lastIndex) {
                address last = _adapters[lastIndex];
                _adapters[index] = last;
                _adapterIndexPlusOne[last] = index + 1;
            }
            _adapters.pop();
            delete _adapterIndexPlusOne[adapter];
        }
        emit WhitelistedAdapterSet(adapter, whitelisted);
    }

    /// @notice Rescue tokens stuck in this contract
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyAdmin {
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    /// @notice Rescue ETH stuck in this contract
    function rescueETH(
        address to
    ) external onlyAdmin {
        SafeTransferLib.safeTransferETH(to, address(this).balance);
    }

    /// ADAPTER ENTRY POINT ///

    /// @notice Execute a swap with bridged tokens. Callable only by
    /// whitelisted adapters which have already transferred tokens here.
    /// @param nativeGasDrop Native gas to leave for `recipient` on this
    /// callback execution chain, denominated in wei. Supported only when
    /// `token` is this chain's wrapped native token.
    /// @param swapDeadline Deadline passed through to `SwapRouter.swap`.
    /// Source-chain senders MUST bound how long the destination swap can
    /// remain executable, otherwise a delayed bridge delivery can still
    /// execute a stale quote whenever `minAmountOut` is met. Pass
    /// `type(uint256).max` to opt out.
    function executeSwap(
        address token,
        uint256 amount,
        address recipient,
        SwapStep[] calldata swapSteps,
        uint256 minAmountOut,
        uint256 nativeGasDrop,
        uint256 swapDeadline
    ) external {
        _onlyWhitelistedAdapter();
        _swapOrFallback(
            token,
            amount,
            recipient,
            swapSteps,
            minAmountOut,
            nativeGasDrop,
            swapDeadline
        );
    }

    /// @notice Execute a swap while reserving native gas from a separately
    /// bridged wrapped-native token.
    /// @param nativeGasDropToken Token delivered by the adapter for the gas
    /// drop. Must be this chain's wrapped native token and must differ from
    /// `token`; use `executeSwap(..., nativeGasDrop)` for primary-WETH drops.
    /// @param nativeGasDrop Amount of `nativeGasDropToken` to unwrap and send
    /// to `recipient`, denominated in wei.
    function executeSwapWithNativeGasDropToken(
        address token,
        uint256 amount,
        address nativeGasDropToken,
        uint256 nativeGasDrop,
        address recipient,
        SwapStep[] calldata swapSteps,
        uint256 minAmountOut,
        uint256 swapDeadline
    ) external {
        _onlyWhitelistedAdapter();
        _swapOrFallbackWithNativeGasDropToken(
            token,
            amount,
            nativeGasDropToken,
            nativeGasDrop,
            recipient,
            swapSteps,
            minAmountOut,
            swapDeadline
        );
    }

    /// INTERNAL ///

    function _onlyWhitelistedAdapter() internal view {
        if (!whitelistedAdapters[msg.sender]) {
            revert NotWhitelistedAdapter();
        }
    }

    /// @dev Approve MSR, attempt swap, fall back to direct transfer on failure
    function _swapOrFallback(
        address token,
        uint256 amount,
        address recipient,
        SwapStep[] calldata swapSteps,
        uint256 minAmountOut,
        uint256 nativeGasDrop,
        uint256 swapDeadline
    ) internal {
        try this.swapExternal(
            token,
            amount,
            recipient,
            swapSteps,
            minAmountOut,
            nativeGasDrop,
            swapDeadline
        ) returns (
            address tokenOut, uint256 swapAmount, uint256 amountOut
        ) {
            emit BridgeSwapExecuted(
                recipient, token, tokenOut, swapAmount, amountOut
            );
        } catch {
            uint256 fallbackAmount =
                _transferAvailable(token, recipient, amount);
            emit BridgeSwapFallback(recipient, token, fallbackAmount);
        }
    }

    function _swapOrFallbackWithNativeGasDropToken(
        address token,
        uint256 amount,
        address nativeGasDropToken,
        uint256 nativeGasDrop,
        address recipient,
        SwapStep[] calldata swapSteps,
        uint256 minAmountOut,
        uint256 swapDeadline
    ) internal {
        try this.swapWithNativeGasDropTokenExternal(
            token,
            amount,
            nativeGasDropToken,
            nativeGasDrop,
            recipient,
            swapSteps,
            minAmountOut,
            swapDeadline
        ) returns (
            address tokenOut, uint256 swapAmount, uint256 amountOut
        ) {
            emit BridgeSwapExecuted(
                recipient, token, tokenOut, swapAmount, amountOut
            );
        } catch {
            uint256 fallbackAmount =
                _transferAvailable(token, recipient, amount);
            if (nativeGasDrop > 0) {
                _transferAvailable(nativeGasDropToken, recipient, nativeGasDrop);
            }
            emit BridgeSwapFallback(recipient, token, fallbackAmount);
        }
    }

    function swapExternal(
        address token,
        uint256 amount,
        address recipient,
        SwapStep[] calldata swapSteps,
        uint256 minAmountOut,
        uint256 nativeGasDrop,
        uint256 swapDeadline
    )
        external
        returns (address tokenOut, uint256 swapAmount, uint256 amountOut)
    {
        if (msg.sender != address(this)) {
            revert OnlySelf();
        }

        swapAmount =
            _reserveNativeGasDrop(token, amount, recipient, nativeGasDrop);
        SafeTransferLib.safeApprove(token, address(msr), 0);
        SafeTransferLib.safeApprove(token, address(msr), swapAmount);

        // Honour the source-side deadline instead of `block.timestamp`.
        amountOut = msr.swap(
            swapSteps, swapAmount, minAmountOut, recipient, swapDeadline
        );

        SafeTransferLib.safeApprove(token, address(msr), 0);
        tokenOut = swapSteps[swapSteps.length - 1].tokenOut;
    }

    function swapWithNativeGasDropTokenExternal(
        address token,
        uint256 amount,
        address nativeGasDropToken,
        uint256 nativeGasDrop,
        address recipient,
        SwapStep[] calldata swapSteps,
        uint256 minAmountOut,
        uint256 swapDeadline
    )
        external
        returns (address tokenOut, uint256 swapAmount, uint256 amountOut)
    {
        if (msg.sender != address(this)) {
            revert OnlySelf();
        }

        _sendNativeGasDropToken(
            token, nativeGasDropToken, recipient, nativeGasDrop
        );
        swapAmount = amount;

        SafeTransferLib.safeApprove(token, address(msr), 0);
        SafeTransferLib.safeApprove(token, address(msr), swapAmount);

        amountOut = msr.swap(
            swapSteps, swapAmount, minAmountOut, recipient, swapDeadline
        );

        SafeTransferLib.safeApprove(token, address(msr), 0);
        tokenOut = swapSteps[swapSteps.length - 1].tokenOut;
    }

    function _reserveNativeGasDrop(
        address token,
        uint256 amount,
        address recipient,
        uint256 nativeGasDrop
    ) internal returns (uint256 swapAmount) {
        if (nativeGasDrop == 0) return amount;
        if (nativeGasDrop >= amount) revert NativeGasDropExceedsAmount();

        address wrappedNative = msr.wrappedNative();
        if (token != wrappedNative) {
            revert NativeGasDropTokenNotWrappedNative();
        }

        IWETHBridgeSwapReceiver(wrappedNative).withdraw(nativeGasDrop);
        SafeTransferLib.safeTransferETH(recipient, nativeGasDrop);

        return amount - nativeGasDrop;
    }

    function _sendNativeGasDropToken(
        address token,
        address nativeGasDropToken,
        address recipient,
        uint256 nativeGasDrop
    ) internal {
        if (nativeGasDrop == 0) return;

        address wrappedNative = msr.wrappedNative();
        if (nativeGasDropToken != wrappedNative) {
            revert NativeGasDropTokenNotWrappedNative();
        }
        if (nativeGasDropToken == token) {
            revert NativeGasDropTokenConflicts();
        }

        IWETHBridgeSwapReceiver(wrappedNative).withdraw(nativeGasDrop);
        SafeTransferLib.safeTransferETH(recipient, nativeGasDrop);
    }

    function _tokenBalance(
        address token,
        address account
    ) internal view returns (uint256) {
        (bool success, bytes memory data) =
            token.staticcall(abi.encodeWithSelector(0x70a08231, account));
        if (!success || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    function _transferAvailable(
        address token,
        address to,
        uint256 amount
    ) internal returns (uint256 sent) {
        uint256 available = _tokenBalance(token, address(this));
        sent = available < amount ? available : amount;
        if (sent > 0) {
            SafeTransferLib.safeTransfer(token, to, sent);
        }
    }

    receive() external payable { }
}
