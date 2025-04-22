// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { EnumerableSet } from
    "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract SickleMultisig {
    using EnumerableSet for EnumerableSet.AddressSet;

    // Transaction states enum
    // Ordering is important here - the first (default) value should be
    // NotCreated,
    // the second Created.
    enum State {
        NotCreated,
        Created,
        Executed,
        Cancelled
    }

    // Data structures

    struct Proposal {
        address[] targets;
        bytes[] calldatas;
        string description;
    }

    struct Transaction {
        // Calls to be executed in the transaction
        Proposal proposal;
        // Transaction state
        State state;
        // Settings nonce that the transaction was created with
        uint256 settingsNonce;
        // Signing state
        address[] signers;
        // Expiration timestamp
        uint256 expirationTimestamp;
    }

    // Errors

    error NotASigner();
    error NotMultisig();

    error InvalidProposal();
    error InvalidThreshold();
    error InvalidExpiration();

    error TransactionDoesNotExist();
    error InsufficientSignatures();
    error TransactionNoLongerValid();
    error TransactionAlreadyExists();
    error TransactionAlreadySigned();
    error TransactionAlreadyExecuted();
    error TransactionAlreadyCancelled();
    error TransactionExpired();

    error SignerAlreadyAdded();
    error SignerAlreadyRemoved();
    error SignerCannotBeRemoved();

    // Events

    event SignerAdded(address signer);
    event SignerRemoved(address signer);

    event ThresholdChanged(uint256 newThreshold);
    event ExpirationChanged(uint32 newExpiration);

    event TransactionProposed(uint256 proposalId, address signer);
    event TransactionSigned(uint256 proposalId, address signer);
    event TransactionExecuted(uint256 proposalId, address signer);
    event TransactionCancelled(uint256 proposalId, address signer);

    // Public storage

    uint256 public threshold;
    uint256 public settingsNonce;
    mapping(uint256 => Transaction) public transactions;
    uint32 public expiration;

    // Private storage

    EnumerableSet.AddressSet private _signers;

    // Initialization

    constructor(
        address initialSigner
    ) {
        // Initialize with only a single signer and a threshold of 1. The signer
        // can add more signers and update the threshold using a proposal.
        _addSigner(initialSigner);
        _setThreshold(1);
        _setExpiration(type(uint32).max);
    }

    // Signer-only actions

    /// @notice Propose a new transaction to be executed from the multisig
    /// @custom:access Restricted to multisig signers.
    function propose(
        Proposal memory proposal
    ) public onlySigner returns (uint256) {
        return _propose(proposal);
    }

    /// @notice Propose a cancellation for a transaction
    /// @custom:access Restricted to multisig signers.
    function proposeCancellation(
        uint256 proposalId
    ) public onlySigner returns (uint256) {
        Proposal memory proposal = Proposal({
            targets: new address[](1),
            calldatas: new bytes[](1),
            description: ""
        });

        proposal.targets[0] = address(this);
        proposal.calldatas[0] = abi.encodeCall(this.cancel, (proposalId));

        return _propose(proposal);
    }

    /// @notice Sign a transaction
    /// @custom:access Restricted to multisig signers.
    function sign(
        uint256 proposalId
    ) public onlySigner {
        _sign(proposalId);
    }

    /// @notice Execute a transaction that has passed the signatures threshold
    /// @custom:access Restricted to multisig signers.
    function execute(
        uint256 proposalId
    ) public onlySigner {
        _execute(proposalId);
    }

    /// @notice Sign a transaction and immediately execute it
    /// @dev Assumes only one signature is missing from the signing threshold.
    /// @custom:access Restricted to multisig signers.
    function signAndExecute(
        uint256 proposalId
    ) public onlySigner {
        _sign(proposalId);
        _execute(proposalId);
    }

    // Multisig-only actions

    /// @notice Cancel a transaction that hasn't been executed or invalidated
    /// @custom:access Restricted to multisig transactions.
    function cancel(
        uint256 proposalId
    ) public onlyMultisig {
        _cancel(proposalId);
    }

    /// @notice Add a signer to the multisig
    /// @custom:access Restricted to multisig transactions.
    function addSigner(
        address signer
    ) public onlyMultisig {
        _addSigner(signer);
    }

    /// @notice Remove a signer from the multisig
    /// @custom:access Restricted to multisig transactions.
    function removeSigner(
        address signer
    ) public onlyMultisig {
        _removeSigner(signer);
    }

    /// @notice Remove a signer from the multisig
    /// @custom:access Restricted to multisig transactions.
    function replaceSigner(
        address oldSigner,
        address newSigner
    ) public onlyMultisig {
        _addSigner(newSigner);
        _removeSigner(oldSigner);
    }

    /// @notice Set a new signatures threshold for the multisig
    /// @custom:access Restricted to multisig transactions.
    function setThreshold(
        uint256 newThreshold
    ) public onlyMultisig {
        _setThreshold(newThreshold);
    }

    /// @notice Set a new transaction expiration for the multisig
    /// @custom:access Restricted to multisig transactions.
    function setExpiration(
        uint32 newExpiration
    ) public onlyMultisig {
        _setExpiration(newExpiration);
    }

    // Public functions

    function signerCount() public view returns (uint256) {
        return _signers.length();
    }

    function signerAddresses() public view returns (address[] memory) {
        return _signers.values();
    }

    function isSigner(
        address signer
    ) public view returns (bool) {
        return _signers.contains(signer);
    }

    function hashProposal(
        Proposal memory proposal
    ) public view returns (uint256) {
        return uint256(
            keccak256(
                abi.encode(
                    block.chainid,
                    proposal.targets,
                    proposal.calldatas,
                    proposal.description
                )
            )
        );
    }

    function getProposal(
        uint256 proposalId
    ) public view returns (Proposal memory) {
        return transactions[proposalId].proposal;
    }

    function exists(
        uint256 proposalId
    ) public view returns (bool) {
        return !_expired(proposalId)
        // We can use >= since enums are just uint8 with extra steps
        && transactions[proposalId].state >= State.Created;
    }

    function executed(
        uint256 proposalId
    ) public view returns (bool) {
        return transactions[proposalId].state == State.Executed;
    }

    function cancelled(
        uint256 proposalId
    ) public view returns (bool) {
        return transactions[proposalId].state == State.Cancelled;
    }

    function expirationTimestamp(
        uint256 proposalId
    ) public view returns (uint256) {
        return transactions[proposalId].expirationTimestamp;
    }

    function signatures(
        uint256 proposalId
    ) public view returns (uint256) {
        return transactions[proposalId].signers.length;
    }

    function signed(
        uint256 proposalId,
        address signer
    ) public view returns (bool) {
        return _hasSigned(proposalId, signer);
    }

    // Modifiers

    modifier onlySigner() {
        if (!isSigner(msg.sender)) {
            revert NotASigner();
        }

        _;
    }

    modifier onlyMultisig() {
        if (msg.sender != address(this)) {
            revert NotMultisig();
        }

        _;
    }

    modifier changesSettings() {
        _;
        settingsNonce += 1;
    }

    // Internals

    function _propose(
        Proposal memory proposal
    ) internal returns (uint256) {
        // Check that the proposal is valid
        if (proposal.targets.length != proposal.calldatas.length) {
            revert InvalidProposal();
        }

        // Hash transaction
        uint256 proposalId = hashProposal(proposal);

        // Expire transaction if needed
        if (_expired(proposalId)) {
            delete transactions[proposalId];
        }

        // Retrieve transaction details
        Transaction storage transaction = transactions[proposalId];

        // Validate transaction state
        if (transaction.state >= State.Created) {
            revert TransactionAlreadyExists();
        }

        // Initialize transaction statue
        transaction.state = State.Created;
        transaction.proposal = proposal;
        transaction.settingsNonce = settingsNonce;
        transaction.expirationTimestamp = block.timestamp + expiration;

        // Emit event
        emit TransactionProposed(proposalId, msg.sender);

        // Add a signature from the current signer
        _sign(proposalId);

        return proposalId;
    }

    function _expired(
        Transaction storage transaction
    ) internal view returns (bool) {
        return transaction.expirationTimestamp < block.timestamp;
    }

    function _expired(
        uint256 proposalId
    ) internal view returns (bool) {
        return _expired(transactions[proposalId]);
    }

    function _validateTransaction(
        Transaction storage transaction
    ) internal view {
        if (transaction.state == State.NotCreated) {
            revert TransactionDoesNotExist();
        }
        if (transaction.state == State.Executed) {
            revert TransactionAlreadyExecuted();
        }
        if (transaction.state == State.Cancelled) {
            revert TransactionAlreadyCancelled();
        }
        if (transaction.settingsNonce != settingsNonce) {
            revert TransactionNoLongerValid();
        }
        if (_expired(transaction)) revert TransactionExpired();
    }

    function _sign(
        uint256 proposalId
    ) internal {
        // Retrieve transaction details
        Transaction storage transaction = transactions[proposalId];

        // Validate transaction state
        _validateTransaction(transaction);
        if (_hasSigned(proposalId, msg.sender)) {
            revert TransactionAlreadySigned();
        }

        // Update transaction state
        transaction.signers.push(msg.sender);

        // Emit event
        emit TransactionSigned(proposalId, msg.sender);
    }

    function _cancel(
        uint256 proposalId
    ) internal {
        // Retrieve transaction details
        Transaction storage transaction = transactions[proposalId];

        // Validate transaction state
        _validateTransaction(transaction);

        // Update transaction state
        transaction.state = State.Cancelled;

        // Emit event
        emit TransactionCancelled(proposalId, msg.sender);
    }

    function _execute(
        uint256 proposalId
    ) internal {
        // Retrieve transaction details
        Transaction storage transaction = transactions[proposalId];

        // Validate transaction state
        _validateTransaction(transaction);

        // Check if the transaction has enough signatures
        if (transaction.signers.length < threshold) {
            revert InsufficientSignatures();
        }

        // Update transaction state
        transaction.state = State.Executed;

        // Execute calls
        uint256 length = transaction.proposal.targets.length;
        for (uint256 i; i < length;) {
            _call(
                transaction.proposal.targets[i],
                transaction.proposal.calldatas[i]
            );

            unchecked {
                ++i;
            }
        }

        // And finally emit event
        emit TransactionExecuted(proposalId, msg.sender);
    }

    function _call(address target, bytes memory data) internal {
        (bool success, bytes memory result) = target.call(data);

        if (!success) {
            assembly {
                revert(add(32, result), mload(result))
            }
        }
    }

    function _addSigner(
        address signer
    ) internal changesSettings {
        if (!_signers.add(signer)) revert SignerAlreadyAdded();
        emit SignerAdded(signer);
    }

    function _removeSigner(
        address signer
    ) internal changesSettings {
        if (signerCount() == 1) revert SignerCannotBeRemoved();

        if (!_signers.remove(signer)) revert SignerAlreadyRemoved();

        emit SignerRemoved(signer);

        if (threshold > signerCount()) {
            _setThreshold(signerCount());
        }
    }

    function _setThreshold(
        uint256 newThreshold
    ) internal changesSettings {
        if (newThreshold > signerCount() || newThreshold == 0) {
            revert InvalidThreshold();
        }

        threshold = newThreshold;

        emit ThresholdChanged(newThreshold);
    }

    function _setExpiration(
        uint32 newExpiration
    ) internal changesSettings {
        if (newExpiration == 0) revert InvalidExpiration();

        expiration = newExpiration;

        emit ExpirationChanged(newExpiration);
    }

    function _hasSigned(
        uint256 proposalId,
        address signer
    ) internal view returns (bool) {
        address[] memory signers = transactions[proposalId].signers;

        for (uint256 i; i < signers.length;) {
            if (signers[i] == signer) return true;
            unchecked {
                ++i;
            }
        }

        return false;
    }
}
