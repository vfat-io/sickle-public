// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    IERC165
} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";
import {
    CcipClient,
    IAny2EVMMessageReceiver
} from "contracts/interfaces/external/chainlink/ICCIPRouterClient.sol";

/// @title CcipAdapterBase
/// @notice Shared CCIP destination auth and token delivery accounting.
abstract contract CcipAdapterBase is
    BridgeAdapterBase,
    IAny2EVMMessageReceiver,
    IERC165
{
    error NotWhitelistedSourceChainSelector(uint64 sourceChainSelector);
    error NotWhitelistedSender(uint64 sourceChainSelector, address sender);
    error InvalidSender();
    error InvalidTokenAmountCount(uint256 count);
    /// Rejected when a CCIP message delivers two `destTokenAmounts` entries
    /// with the same token. The canonical sender already enforces uniqueness,
    /// but the destination adapters now mirror that invariant defensively so
    /// a misconfigured sender cannot leave the second leg stranded as
    /// accounted balance.
    error DuplicateDeliveredToken(address token);

    event WhitelistedSourceChainSelectorSet(
        uint64 indexed sourceChainSelector, bool whitelisted
    );
    event WhitelistedSenderSet(
        uint64 indexed sourceChainSelector,
        address indexed sender,
        bool whitelisted
    );
    event AccountedTokenBalanceSynced(address indexed token, uint256 balance);

    mapping(uint64 => bool) public whitelistedSourceChainSelectors;
    uint64[] private _sourceChainSelectors;
    mapping(uint64 => uint256) private _sourceChainSelectorIndexPlusOne;

    struct MessageSender {
        uint64 sourceChainSelector;
        address sender;
    }

    mapping(uint64 => mapping(address => bool)) public whitelistedSenders;
    MessageSender[] private _senders;
    mapping(uint64 => mapping(address => uint256)) private _senderIndexPlusOne;
    mapping(address => uint256) public accountedTokenBalances;

    constructor(
        address admin_,
        address guardian_
    ) BridgeAdapterBase(admin_, guardian_) { }

    function sourceChainSelectors() external view returns (uint64[] memory) {
        return _sourceChainSelectors;
    }

    function senders() external view returns (MessageSender[] memory) {
        return _senders;
    }

    function setWhitelistedSourceChainSelector(
        uint64 sourceChainSelector,
        bool whitelisted
    ) external onlyAdmin {
        bool currentlyAllowed =
            whitelistedSourceChainSelectors[sourceChainSelector];
        if (currentlyAllowed == whitelisted) return;

        whitelistedSourceChainSelectors[sourceChainSelector] = whitelisted;
        if (whitelisted) {
            _sourceChainSelectorIndexPlusOne[sourceChainSelector] =
                _sourceChainSelectors.length + 1;
            _sourceChainSelectors.push(sourceChainSelector);
        } else {
            uint256 indexPlusOne =
                _sourceChainSelectorIndexPlusOne[sourceChainSelector];
            uint256 index = indexPlusOne - 1;
            uint256 lastIndex = _sourceChainSelectors.length - 1;
            if (index != lastIndex) {
                uint64 last = _sourceChainSelectors[lastIndex];
                _sourceChainSelectors[index] = last;
                _sourceChainSelectorIndexPlusOne[last] = index + 1;
            }
            _sourceChainSelectors.pop();
            delete _sourceChainSelectorIndexPlusOne[sourceChainSelector];
        }

        emit WhitelistedSourceChainSelectorSet(sourceChainSelector, whitelisted);
    }

    function setWhitelistedSender(
        uint64 sourceChainSelector,
        address sender,
        bool whitelisted
    ) external onlyAdmin {
        bool currentlyAllowed = whitelistedSenders[sourceChainSelector][sender];
        if (currentlyAllowed == whitelisted) return;

        whitelistedSenders[sourceChainSelector][sender] = whitelisted;
        if (whitelisted) {
            _senderIndexPlusOne[sourceChainSelector][sender] =
                _senders.length + 1;
            _senders.push(
                MessageSender({
                    sourceChainSelector: sourceChainSelector, sender: sender
                })
            );
        } else {
            uint256 indexPlusOne =
                _senderIndexPlusOne[sourceChainSelector][sender];
            uint256 index = indexPlusOne - 1;
            uint256 lastIndex = _senders.length - 1;
            if (index != lastIndex) {
                MessageSender memory last = _senders[lastIndex];
                _senders[index] = last;
                _senderIndexPlusOne[last.sourceChainSelector][last.sender] =
                    index + 1;
            }
            _senders.pop();
            delete _senderIndexPlusOne[sourceChainSelector][sender];
        }

        emit WhitelistedSenderSet(sourceChainSelector, sender, whitelisted);
    }

    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external override onlyAdmin {
        SafeTransferLib.safeTransfer(token, to, amount);
        _syncAccountedTokenBalance(token);
    }

    function syncAccountedTokenBalance(
        address token
    ) external onlyAdmin {
        _syncAccountedTokenBalance(token);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) external pure override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function _authorizeMessage(
        CcipClient.Any2EVMMessage calldata message
    ) internal view returns (address sender) {
        _onlyWhitelistedEndpoint();
        if (!whitelistedSourceChainSelectors[message.sourceChainSelector]) {
            revert NotWhitelistedSourceChainSelector(message.sourceChainSelector);
        }

        sender = _decodeEvmSender(message.sender);
        if (!whitelistedSenders[message.sourceChainSelector][sender]) {
            revert NotWhitelistedSender(message.sourceChainSelector, sender);
        }
    }

    function _singleTokenAmount(
        CcipClient.Any2EVMMessage calldata message
    ) internal pure returns (CcipClient.EVMTokenAmount calldata tokenAmount) {
        if (message.destTokenAmounts.length != 1) {
            revert InvalidTokenAmountCount(message.destTokenAmounts.length);
        }
        tokenAmount = message.destTokenAmounts[0];
    }

    function _decodeEvmSender(
        bytes calldata sender
    ) internal pure returns (address) {
        if (sender.length != 32) revert InvalidSender();
        return abi.decode(sender, (address));
    }

    function _syncAccountedTokenBalance(
        address token
    ) internal {
        uint256 balance = _tokenBalance(token);
        accountedTokenBalances[token] = balance;
        emit AccountedTokenBalanceSynced(token, balance);
    }

    /// @dev Reverts when both entries in a CCIP `destTokenAmounts` reference
    /// the same token, so `_forwardDelivered` cannot silently strand the
    /// second leg.
    function _requireDistinctTokens(
        address tokenA,
        address tokenB
    ) internal pure {
        if (tokenA == tokenB) revert DuplicateDeliveredToken(tokenA);
    }

    function _forwardDelivered(
        address token,
        uint256 expectedAmount,
        address to
    ) internal returns (uint256 receivedByTarget) {
        uint256 accounted = accountedTokenBalances[token];
        uint256 current = _tokenBalance(token);
        uint256 delivered = current > accounted ? current - accounted : 0;
        uint256 sendAmount =
            delivered < expectedAmount ? delivered : expectedAmount;

        if (sendAmount == 0) {
            accountedTokenBalances[token] = current;
            return 0;
        }

        uint256 targetBefore = _tokenBalanceOf(token, to);
        SafeTransferLib.safeTransfer(token, to, sendAmount);
        uint256 targetAfter = _tokenBalanceOf(token, to);
        accountedTokenBalances[token] = _tokenBalance(token);
        if (targetAfter > targetBefore) {
            receivedByTarget = targetAfter - targetBefore;
        }
    }

    function _tokenBalanceOf(
        address token,
        address account
    ) internal view returns (uint256) {
        (bool success, bytes memory data) =
            token.staticcall(abi.encodeWithSelector(0x70a08231, account));
        if (!success || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }
}
