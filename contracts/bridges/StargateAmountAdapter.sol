// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { ReentrancyGuard } from "solmate/utils/ReentrancyGuard.sol";
import { GuardianAdmin } from "contracts/base/GuardianAdmin.sol";
import {
    IBridgeAmountAdapter
} from "contracts/interfaces/IBridgeAmountAdapter.sol";
import {
    IStargateV2,
    StargateSendParam,
    StargateMessagingFee,
    StargateMessagingReceipt,
    StargateOFTLimit,
    StargateOFTReceipt
} from "contracts/interfaces/external/stargate/IStargateV2.sol";

interface IWETHStargateAmount {
    function withdraw(
        uint256 amount
    ) external;
}

/// @title StargateAmountAdapter
/// @notice Source-side Stargate V2 adapter for BridgeRouter exact-amount
/// routes, including routes whose bridge amount is only known after a swap.
/// @dev Stargate fees are quoted against the final SendParam. This adapter
/// first observes the runtime amount, asks quoteOFT to apply live path-credit
/// caps and shared-decimal alignment, rebuilds amountLD from amountSentLD, and
/// only then calls quoteSend on-chain. Destination-side Stargate adapters do
/// not solve this: they run after delivery and cannot update or fund a source
/// send whose amount changed during a source swap.
contract StargateAmountAdapter is
    GuardianAdmin,
    ReentrancyGuard,
    IBridgeAmountAdapter
{
    error ZeroAddress();
    error PausedError();
    error PoolNotAContract(address pool);
    error NotWhitelistedPool(address pool);
    error PoolTokenMismatch(address pool, address supplied, address actual);
    error InvalidBridgeToken(address supplied, address required);
    error InvalidDestinationEid();
    error ZeroRecipient();
    error ComposeRequiresTaxi();
    error ZeroAmountReceived();
    error InvalidOFTQuote(
        uint256 amountSentLD, uint256 minAmountLD, uint256 maxAmountLD
    );
    error OutputAmountTooLow(uint256 amountReceivedLD, uint256 minAmountLD);
    error LzTokenFeeUnsupported(uint256 lzTokenFee);
    error IncorrectNativeFee(uint256 supplied, uint256 required);
    error SendReceiptMismatch(
        uint256 quotedSentLD,
        uint256 actualSentLD,
        uint256 quotedReceivedLD,
        uint256 actualReceivedLD
    );

    event PausedSet(bool paused);
    event WhitelistedPoolSet(
        address indexed pool, address indexed token, bool whitelisted
    );
    event TokensRescued(
        address indexed token, address indexed to, uint256 amount
    );
    event ETHRescued(address indexed to, uint256 amount);
    event StargateExactAmountBridge(
        bytes32 indexed guid,
        address indexed caller,
        address indexed pool,
        address bridgeToken,
        uint256 runtimeAmount,
        uint256 amountSentLD,
        uint256 amountReceivedLD,
        uint256 nativeFee
    );

    struct ExactAmountParams {
        address pool;
        StargateSendParam sendParam;
    }

    struct PreparedSend {
        StargateSendParam sendParam;
        StargateOFTReceipt oftReceipt;
        StargateMessagingFee messagingFee;
    }

    struct CompletedSend {
        bytes32 guid;
        uint256 amountSentLD;
        uint256 amountReceivedLD;
        uint256 nativeFee;
    }

    /// @notice Wrapped native token used as BridgeRouter's ERC20-facing token
    /// for Stargate native pools.
    address public immutable weth;

    bool public paused;
    mapping(address => bool) public whitelistedPools;
    /// @notice Underlying token reported by the Stargate contract.
    /// address(0) identifies a native pool, whose BridgeRouter token is WETH.
    mapping(address => address) public poolTokens;

    address[] private _pools;
    mapping(address => uint256) private _poolIndexPlusOne;

    constructor(
        address admin_,
        address guardian_,
        address weth_
    ) GuardianAdmin(admin_, guardian_) {
        if (weth_ == address(0)) revert ZeroAddress();
        weth = weth_;
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

    function pools() external view returns (address[] memory) {
        return _pools;
    }

    /// @notice Adds or removes a Stargate Pool/OFT source contract. `token`
    /// must match the contract's immutable token(); use address(0) for a
    /// native pool.
    function setWhitelistedPool(
        address pool,
        address token,
        bool whitelisted
    ) external onlyAdmin {
        _setWhitelistedPool(pool, token, whitelisted);
    }

    /// @notice Emergency-disable one Stargate source without waiting for the
    /// admin path. Re-enabling remains admin-only.
    function emergencyDisablePool(
        address pool
    ) external onlyGuardianOrAdmin {
        _setWhitelistedPool(pool, poolTokens[pool], false);
    }

    /// @notice Returns the live normalized send and native fee for an
    /// anticipated bridge amount. Execution repeats both quotes after pulling
    /// the actual runtime amount.
    function quoteExactAmount(
        address bridgeToken,
        uint256 amount,
        bytes calldata params
    )
        external
        view
        returns (
            uint256 amountSentLD,
            uint256 amountReceivedLD,
            uint256 nativeFee
        )
    {
        ExactAmountParams memory decoded =
            abi.decode(params, (ExactAmountParams));
        PreparedSend memory prepared =
            _prepareSend(bridgeToken, amount, decoded);
        return (
            prepared.oftReceipt.amountSentLD,
            prepared.oftReceipt.amountReceivedLD,
            prepared.messagingFee.nativeFee
        );
    }

    function bridgeExactAmount(
        address bridgeToken,
        uint256 amount,
        bytes calldata params
    ) external payable override nonReentrant returns (bytes memory result) {
        if (paused) revert PausedError();

        uint256 nativeBalanceBefore = address(this).balance - msg.value;
        ExactAmountParams memory decoded =
            abi.decode(params, (ExactAmountParams));

        _requireBridgeToken(decoded.pool, bridgeToken);
        uint256 received = _pullAvailable(bridgeToken, amount);
        if (received == 0) revert ZeroAmountReceived();

        PreparedSend memory prepared =
            _prepareSend(bridgeToken, received, decoded);
        CompletedSend memory completed = _executeSend(
            decoded.pool, bridgeToken, received, prepared, nativeBalanceBefore
        );

        emit StargateExactAmountBridge(
            completed.guid,
            msg.sender,
            decoded.pool,
            bridgeToken,
            received,
            completed.amountSentLD,
            completed.amountReceivedLD,
            completed.nativeFee
        );

        return abi.encode(
            completed.guid,
            completed.amountSentLD,
            completed.amountReceivedLD,
            completed.nativeFee
        );
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
        address to,
        uint256 amount
    ) external onlyAdmin {
        SafeTransferLib.safeTransferETH(to, amount);
        emit ETHRescued(to, amount);
    }

    function _prepareSend(
        address bridgeToken,
        uint256 amount,
        ExactAmountParams memory decoded
    ) internal view returns (PreparedSend memory prepared) {
        _requireBridgeToken(decoded.pool, bridgeToken);
        _validateSendParam(decoded.sendParam);

        decoded.sendParam.amountLD = amount;
        StargateOFTLimit memory limit;
        (limit,, prepared.oftReceipt) =
            IStargateV2(decoded.pool).quoteOFT(decoded.sendParam);

        uint256 amountSentLD = prepared.oftReceipt.amountSentLD;
        if (
            amountSentLD == 0 || amountSentLD > amount
                || amountSentLD < limit.minAmountLD
                || amountSentLD > limit.maxAmountLD
        ) {
            revert InvalidOFTQuote(
                amountSentLD, limit.minAmountLD, limit.maxAmountLD
            );
        }
        if (
            prepared.oftReceipt.amountReceivedLD < decoded.sendParam.minAmountLD
        ) {
            revert OutputAmountTooLow(
                prepared.oftReceipt.amountReceivedLD,
                decoded.sendParam.minAmountLD
            );
        }

        // quoteOFT applies live credit caps and shared-decimal de-dusting.
        // quoteSend must see precisely the amount that sendToken will debit.
        decoded.sendParam.amountLD = amountSentLD;
        prepared.sendParam = decoded.sendParam;
        prepared.messagingFee =
            IStargateV2(decoded.pool).quoteSend(prepared.sendParam, false);
        if (prepared.messagingFee.lzTokenFee != 0) {
            revert LzTokenFeeUnsupported(prepared.messagingFee.lzTokenFee);
        }
    }

    function _executeSend(
        address pool,
        address bridgeToken,
        uint256 received,
        PreparedSend memory prepared,
        uint256 nativeBalanceBefore
    ) internal returns (CompletedSend memory completed) {
        completed.nativeFee = prepared.messagingFee.nativeFee;
        if (msg.value < completed.nativeFee) {
            revert IncorrectNativeFee(msg.value, completed.nativeFee);
        }

        address poolToken = poolTokens[pool];
        uint256 sendValue = completed.nativeFee;
        if (poolToken == address(0)) {
            IWETHStargateAmount(weth).withdraw(prepared.oftReceipt.amountSentLD);
            sendValue += prepared.oftReceipt.amountSentLD;
        } else {
            SafeTransferLib.safeApprove(poolToken, pool, 0);
            SafeTransferLib.safeApprove(
                poolToken, pool, prepared.oftReceipt.amountSentLD
            );
        }

        StargateMessagingReceipt memory messageReceipt;
        StargateOFTReceipt memory actualReceipt;
        (messageReceipt, actualReceipt,) = IStargateV2(pool)
        .sendToken{ value: sendValue }(
            prepared.sendParam, prepared.messagingFee, address(this)
        );

        if (poolToken != address(0)) {
            SafeTransferLib.safeApprove(poolToken, pool, 0);
        }
        _requireMatchingReceipt(prepared.oftReceipt, actualReceipt);

        completed.guid = messageReceipt.guid;
        completed.amountSentLD = actualReceipt.amountSentLD;
        completed.amountReceivedLD = actualReceipt.amountReceivedLD;

        uint256 tokenSurplus = received - completed.amountSentLD;
        if (tokenSurplus > 0) {
            SafeTransferLib.safeTransfer(bridgeToken, msg.sender, tokenSurplus);
        }
        uint256 nativeSurplus = address(this).balance - nativeBalanceBefore;
        if (nativeSurplus > 0) {
            SafeTransferLib.safeTransferETH(msg.sender, nativeSurplus);
        }
    }

    function _requireMatchingReceipt(
        StargateOFTReceipt memory quoted,
        StargateOFTReceipt memory actual
    ) internal pure {
        if (
            actual.amountSentLD != quoted.amountSentLD
                || actual.amountReceivedLD != quoted.amountReceivedLD
        ) {
            revert SendReceiptMismatch(
                quoted.amountSentLD,
                actual.amountSentLD,
                quoted.amountReceivedLD,
                actual.amountReceivedLD
            );
        }
    }

    function _validateSendParam(
        StargateSendParam memory sendParam
    ) internal pure {
        if (sendParam.dstEid == 0) revert InvalidDestinationEid();
        if (sendParam.to == bytes32(0)) revert ZeroRecipient();
        if (sendParam.composeMsg.length > 0 && sendParam.oftCmd.length > 0) {
            revert ComposeRequiresTaxi();
        }
    }

    function _requireBridgeToken(
        address pool,
        address bridgeToken
    ) internal view {
        if (!whitelistedPools[pool]) revert NotWhitelistedPool(pool);
        address poolToken = poolTokens[pool];
        address requiredToken = poolToken == address(0) ? weth : poolToken;
        if (bridgeToken != requiredToken) {
            revert InvalidBridgeToken(bridgeToken, requiredToken);
        }
    }

    function _pullAvailable(
        address token,
        uint256 amount
    ) internal returns (uint256 received) {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        SafeTransferLib.safeTransferFrom(
            token, msg.sender, address(this), amount
        );
        received = IERC20(token).balanceOf(address(this)) - balanceBefore;
    }

    function _setWhitelistedPool(
        address pool,
        address token,
        bool whitelisted
    ) internal {
        if (whitelisted) {
            if (pool.code.length == 0) revert PoolNotAContract(pool);
            address actualToken = IStargateV2(pool).token();
            if (actualToken != token) {
                revert PoolTokenMismatch(pool, token, actualToken);
            }
        }

        bool currentlyAllowed = whitelistedPools[pool];
        if (currentlyAllowed == whitelisted) {
            if (whitelisted && poolTokens[pool] != token) {
                poolTokens[pool] = token;
                emit WhitelistedPoolSet(pool, token, true);
            }
            return;
        }

        whitelistedPools[pool] = whitelisted;
        if (whitelisted) {
            poolTokens[pool] = token;
            _poolIndexPlusOne[pool] = _pools.length + 1;
            _pools.push(pool);
            emit WhitelistedPoolSet(pool, token, true);
            return;
        }

        uint256 index = _poolIndexPlusOne[pool] - 1;
        uint256 lastIndex = _pools.length - 1;
        if (index != lastIndex) {
            address last = _pools[lastIndex];
            _pools[index] = last;
            _poolIndexPlusOne[last] = index + 1;
        }
        _pools.pop();
        delete _poolIndexPlusOne[pool];
        emit WhitelistedPoolSet(pool, poolTokens[pool], false);
    }

    receive() external payable { }
}
