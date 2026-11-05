// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";
import {
    OFTComposeMsgCodec
} from "contracts/bridges/libraries/OFTComposeMsgCodec.sol";
import {
    ILayerZeroComposer
} from "contracts/bridges/interfaces/ILayerZeroComposer.sol";

interface IWETHStargate {
    function deposit() external payable;
}

/// @title StargateAdapterBase
/// @notice Shared Stargate adapter configuration and compose authentication.
abstract contract StargateAdapterBase is BridgeAdapterBase, ILayerZeroComposer {
    error NotWhitelistedPool(address pool);
    error NotWhitelistedSourceEid(uint32 srcEid);
    error InsufficientNativeBalance(uint256 expectedAmount, uint256 actualBalance);
    error InsufficientTokenBalance(
        address token, uint256 expectedAmount, uint256 actualBalance
    );
    /// Thrown when a compose `_guid` has already been consumed. Prevents
    /// replaying a failed-then-rescued compose against later same-token
    /// balances on the adapter.
    error ComposeAlreadyConsumed(bytes32 guid);
    /// @dev Used by adapter-side try/catch self-calls so guid consumption
    /// persists across downstream reverts.
    error OnlySelf();

    event WhitelistedPoolSet(address pool, address token, bool whitelisted);
    event WhitelistedSourceEidSet(uint32 srcEid, bool whitelisted);

    /// @notice Emitted when a compose `_guid` is marked consumed —
    /// either by a successful authorize-and-consume or by an admin
    /// explicitly invalidating it during a rescue.
    event ComposeGuidConsumed(bytes32 indexed guid);

    /// @notice Emitted when the outer `lzCompose` authorized a guid but
    /// the inner processing reverted.
    /// The guid stays consumed (so a LayerZero retry cannot replay against
    /// later same-token funds), the inbound tokens stay parked on the
    /// adapter, and admins must rescue them via `rescueTokens` /
    /// `rescueETH`. `reason` is the raw revert payload from the inner
    /// self-call for off-chain triage.
    event ComposeProcessingFailed(
        bytes32 indexed guid,
        address indexed from,
        uint32 indexed srcEid,
        bytes32 composeFrom,
        bytes reason
    );

    /// @notice Stargate pool / OFT addresses authorized to compose into this
    /// adapter.
    mapping(address => bool) public whitelistedPools;

    /// @notice Token address per whitelisted Stargate sender.
    /// @dev address(0) for native ETH pools.
    mapping(address => address) public poolTokens;

    /// @notice LayerZero source endpoint IDs allowed to reach this adapter.
    mapping(uint32 => bool) public whitelistedSourceEids;

    address[] private _pools;
    mapping(address => uint256) private _poolIndexPlusOne;
    uint32[] private _sourceEids;
    mapping(uint32 => uint256) private _sourceEidIndexPlusOne;

    /// @notice Tracks LayerZero compose `_guid`s already authenticated by
    /// this adapter (whether the downstream call succeeded or reverted).
    /// A consumed guid can never be replayed against later same-token
    /// balances on the adapter. Admins can invalidate additional guids
    /// explicitly via `invalidateComposeGuid` before or alongside a
    /// `rescueTokens` / `rescueETH` recovery.
    mapping(bytes32 guid => bool consumed) public consumedComposeGuid;

    /// @notice WETH (or equivalent wrapped-native) used to wrap native ETH
    /// pool deliveries before forwarding downstream.
    address public immutable weth;

    constructor(
        address admin_,
        address guardian_,
        address weth_
    ) BridgeAdapterBase(admin_, guardian_) {
        weth = weth_;
    }

    /// @notice LayerZero V2 compose callback. Authorizes the guid (consuming
    /// it irreversibly via `_authorizeCompose`) then dispatches the downstream
    /// processing via an external self-call wrapped in try/catch. If the inner
    /// work reverts, the guid stays consumed — LayerZero retries cannot replay
    /// against later same-token balances — and the inbound tokens stay parked
    /// for admin rescue.
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address,
        bytes calldata
    ) external payable override {
        (
            address token,
            uint256 amountLD,
            bytes calldata userPayload,
            uint32 srcEid,
            bytes32 composeFrom
        ) = _authorizeCompose(_from, _guid, _message);

        try this.lzComposeExternal{ value: msg.value }(
            token, amountLD, userPayload, srcEid, composeFrom
        ) {
            // success
        } catch (bytes memory reason) {
            emit ComposeProcessingFailed(
                _guid, _from, srcEid, composeFrom, reason
            );
        }
    }

    /// @dev Self-callable inner dispatcher. Reverts on validation /
    /// downstream failure; the outer try/catch in `lzCompose` keeps the
    /// guid consumed regardless.
    function lzComposeExternal(
        address token,
        uint256 amountLD,
        bytes calldata userPayload,
        uint32 srcEid,
        bytes32 composeFrom
    ) external payable {
        if (msg.sender != address(this)) revert OnlySelf();
        _processCompose(token, amountLD, userPayload, srcEid, composeFrom);
    }

    /// @dev Adapter-specific compose handler. Implementations decode the
    /// user payload, prepare the inbound token via `_prepareInboundToken`,
    /// and forward to the downstream receiver/strategy.
    function _processCompose(
        address token,
        uint256 amountLD,
        bytes calldata userPayload,
        uint32 srcEid,
        bytes32 composeFrom
    ) internal virtual;

    /// @dev Native pool (token == address(0)): wraps exactly `amountLD` of
    /// the delivered ETH to WETH. ERC20 pool: validates the local balance
    /// is at least `amountLD`. Returns the effective token to forward.
    function _prepareInboundToken(
        address token,
        uint256 amountLD
    ) internal returns (address) {
        if (token == address(0)) {
            // `msg.value` is a separate LayerZero native drop (forwarded
            // downstream by the route adapter), not part of the bridged
            // delivery — exclude it so wrapping `amountLD` cannot dip into it.
            uint256 balance = address(this).balance - msg.value;
            if (balance < amountLD) {
                revert InsufficientNativeBalance(amountLD, balance);
            }
            IWETHStargate(weth).deposit{ value: amountLD }();
            return weth;
        }
        _requireSufficientTokenBalance(token, amountLD);
        return token;
    }

    receive() external payable { }

    function pools() external view returns (address[] memory) {
        return _pools;
    }

    function sourceEids() external view returns (uint32[] memory) {
        return _sourceEids;
    }

    function setWhitelistedPool(
        address pool,
        address token,
        bool whitelisted
    ) external onlyAdmin {
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

        uint256 indexPlusOne = _poolIndexPlusOne[pool];
        uint256 index = indexPlusOne - 1;
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

    function setWhitelistedSourceEid(
        uint32 srcEid,
        bool whitelisted
    ) external onlyAdmin {
        bool currentlyAllowed = whitelistedSourceEids[srcEid];
        if (currentlyAllowed == whitelisted) return;

        whitelistedSourceEids[srcEid] = whitelisted;
        if (whitelisted) {
            _sourceEidIndexPlusOne[srcEid] = _sourceEids.length + 1;
            _sourceEids.push(srcEid);
        } else {
            uint256 indexPlusOne = _sourceEidIndexPlusOne[srcEid];
            uint256 index = indexPlusOne - 1;
            uint256 lastIndex = _sourceEids.length - 1;
            if (index != lastIndex) {
                uint32 last = _sourceEids[lastIndex];
                _sourceEids[index] = last;
                _sourceEidIndexPlusOne[last] = index + 1;
            }
            _sourceEids.pop();
            delete _sourceEidIndexPlusOne[srcEid];
        }
        emit WhitelistedSourceEidSet(srcEid, whitelisted);
    }

    function _requireSufficientTokenBalance(
        address token,
        uint256 amountLD
    ) internal view {
        uint256 balance = _tokenBalance(token);
        if (balance < amountLD) {
            revert InsufficientTokenBalance(token, amountLD, balance);
        }
    }

    function _authorizeCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message
    )
        internal
        returns (
            address token,
            uint256 amountLD,
            bytes calldata userPayload,
            uint32 srcEid,
            bytes32 composeFrom
        )
    {
        _onlyWhitelistedEndpoint();
        if (!whitelistedPools[_from]) revert NotWhitelistedPool(_from);

        srcEid = OFTComposeMsgCodec.srcEid(_message);
        if (!whitelistedSourceEids[srcEid]) {
            revert NotWhitelistedSourceEid(srcEid);
        }

        // Mark the compose guid as consumed. The flag only persists across
        // a downstream revert when the **caller** (each Stargate adapter's
        // `lzCompose`) wraps the downstream processing in a try/catch
        // self-call so the outer transaction does not revert. Without that
        // pattern, the outer revert would roll back this assignment and the
        // LayerZero compose would remain replayable.
        if (consumedComposeGuid[_guid]) {
            revert ComposeAlreadyConsumed(_guid);
        }
        consumedComposeGuid[_guid] = true;
        emit ComposeGuidConsumed(_guid);

        composeFrom = OFTComposeMsgCodec.composeFrom(_message);

        token = poolTokens[_from];
        amountLD = OFTComposeMsgCodec.amountLD(_message);
        userPayload = OFTComposeMsgCodec.composeMsg(_message);
    }

    /// @notice Admin handle to invalidate a compose `_guid` so it can
    /// never trigger an `lzCompose` callback on this adapter. Intended to
    /// pair with `rescueTokens` /
    /// `rescueETH` after a failed delivery: rescue the parked funds, then
    /// (or simultaneously) invalidate the guid so the still-queued
    /// LayerZero compose cannot replay against a later balance.
    function invalidateComposeGuid(
        bytes32 guid
    ) external onlyAdmin {
        if (consumedComposeGuid[guid]) return;
        consumedComposeGuid[guid] = true;
        emit ComposeGuidConsumed(guid);
    }
}
