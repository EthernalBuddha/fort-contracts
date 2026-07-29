// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Thrown when the caller is not one of the three safe owners.
error NotOwner();
/// @dev Thrown when an owner address is the zero address.
error ZeroOwner();
/// @dev Thrown when the three owner addresses are not all distinct.
error OwnersMustDiffer();
/// @dev Thrown when a transaction id is out of range.
error BadId();
/// @dev Thrown when the recipient is the zero address or the safe itself.
error BadRecipient();
/// @dev Thrown when a transaction carries neither value nor calldata.
error EmptyTransaction();
/// @dev Thrown when calldata exceeds MAX_DATA_LENGTH.
error DataTooLong();
/// @dev Thrown when a new transaction would reserve more than the free balance.
error ExceedsAvailableBalance();
/// @dev Thrown when the transaction has already been executed.
error AlreadyExecuted();
/// @dev Thrown when the transaction has already been canceled.
error TransactionCanceled();
/// @dev Thrown when the caller has already confirmed the transaction.
error AlreadyConfirmed();
/// @dev Thrown when the caller has not confirmed the transaction.
error NotConfirmed();
/// @dev Thrown when there is no confirmation left to revoke.
/// Unreachable while the confirmed/confirms invariant holds; kept as a defensive check.
error NoConfirmations();
/// @dev Thrown when the caller has already voted to cancel.
error AlreadyVotedToCancel();
/// @dev Thrown when the caller has not voted to cancel.
error NotVotedToCancel();
/// @dev Thrown when there is no cancel vote left to revoke.
/// Unreachable while the cancelVoted/cancelVotes invariant holds; kept as a defensive check.
error NoCancelVotes();
/// @dev Thrown when the transaction has fewer than THRESHOLD confirmations.
error NotEnoughConfirmations();
/// @dev Thrown when the safe balance is lower than the transaction amount.
error InsufficientBalance();
/// @dev Thrown when the outbound call fails.
error TransferFailed();
/// @dev Thrown when a safe name exceeds MAX_NAME_LENGTH bytes.
error NameTooLong();
/// @dev Thrown when cancelling a transaction that already reached THRESHOLD confirmations.
/// Such a transaction is not stuck: any confirming owner can call revokeConfirm first, which
/// drops the count below THRESHOLD and re-enables the normal cancel flow.
error QuorumReached();

/// @dev Reverts unless all three owners are non-zero and distinct.
/// Shared by Save and SaveFactory. Free functions are always internal,
/// so no visibility keyword may be given here.
function _validateOwners(address[3] memory o) pure {
    if (o[0] == address(0) || o[1] == address(0) || o[2] == address(0)) revert ZeroOwner();
    if (o[0] == o[1] || o[0] == o[2] || o[1] == o[2]) revert OwnersMustDiffer();
}

/// @title Save
/// @notice A 2-of-3 multisig safe: three fixed owners, two confirmations to execute.
/// @dev Owners and threshold are set at construction and cannot change. Moving to
/// N-of-M would change the constructor, the factory and the frontend, so it is out of scope.
/// Reentrancy protection comes from OpenZeppelin's ReentrancyGuard; executeTx also
/// follows checks-effects-interactions, so the guard is a second line of defence.
contract Save is ReentrancyGuard {
    /// @notice Number of confirmations required to execute a transaction, and number of cancel
    /// votes required to cancel one that has not yet reached that many confirmations.
    /// @dev Cancellation is deliberately not symmetric with execution. Once confirms reaches
    /// THRESHOLD the transaction can no longer be canceled at all, so that a cancel vote cannot
    /// race an execution that is already authorized. To unwind such a transaction, one of the
    /// confirming owners calls revokeConfirm first; the count drops below THRESHOLD and the
    /// normal cancel flow becomes available again. The same path is the way out of a transaction
    /// whose recipient always reverts: it can never execute, and until a confirmation is revoked
    /// its amount keeps reducing availableBalance().
    uint8 public constant THRESHOLD = 2;

    /// @notice Maximum calldata size, in bytes, accepted by a transaction.
    uint256 public constant MAX_DATA_LENGTH = 4096;

    /// @notice The three safe owners, in the order given at construction.
    address[3] public owners;

    /// @notice Stored transaction record.
    /// @dev executedBlock stays 0 until the transaction is executed.
    struct Tx {
        address to;
        uint256 amount;
        bool executed;
        uint8 confirms;
        uint64 createdBlock;
        uint64 executedBlock;
        bytes data;
    }

    /// @dev Read via getTx / getTxFull / getTxs - the public getter is omitted on purpose.
    Tx[] internal txs;

    /// @notice Whether a given owner has confirmed a given transaction.
    mapping(uint256 => mapping(address => bool)) public confirmed;

    /// @notice Whether a given transaction has been canceled.
    mapping(uint256 => bool) public canceled;

    /// @notice The owner that created a given transaction.
    mapping(uint256 => address) public proposer;

    /// @notice Number of cancel votes collected for a given transaction.
    mapping(uint256 => uint8) public cancelVotes;

    /// @notice Whether a given owner has voted to cancel a given transaction.
    mapping(uint256 => mapping(address => bool)) public cancelVoted;

    /// @notice Total amount across all created transactions that are neither executed nor canceled.
    /// @dev Prevents committing more funds than the contract currently holds.
    /// Native currency only: a transaction that moves ERC-20 tokens through its calldata reserves
    /// nothing here, so availableBalance() makes no statement about token balances.
    uint256 public pendingAmount;

    /// @notice Flat transaction snapshot, readable in a single call.
    /// @dev Includes calldata; for large histories prefer getTxSummaries.
    struct TxView {
        uint256 id;
        address to;
        uint256 amount;
        bool executed;
        uint8 confirms;
        bool isCanceled;
        address txProposer;
        uint8 cancelVoteCount;
        uint64 createdBlock;
        uint64 executedBlock;
        bool[3] confirmedBy;
        bytes data;
    }

    /// @notice Transaction snapshot without calldata, for cheap list rendering.
    /// @dev Response size is bounded, unlike TxView which carries up to MAX_DATA_LENGTH bytes per entry.
    struct TxSummary {
        uint256 id;
        address to;
        uint256 amount;
        bool executed;
        uint8 confirms;
        bool isCanceled;
        address txProposer;
        uint8 cancelVoteCount;
        uint64 createdBlock;
        uint64 executedBlock;
        bool[3] confirmedBy;
        uint256 dataLength;
    }

    /// @notice Emitted when the safe receives native currency.
    event Deposit(address indexed from, uint256 amount, uint256 balance);
    /// @notice Emitted when an owner creates a transaction.
    event TxCreated(uint256 indexed id, address indexed proposer, address indexed to, uint256 amount);
    /// @notice Emitted when an owner confirms a transaction.
    event TxConfirmed(uint256 indexed id, address indexed owner, uint8 confirms);
    /// @notice Emitted when an owner revokes a confirmation.
    event TxRevoked(uint256 indexed id, address indexed owner, uint8 confirms);
    /// @notice Emitted when an owner votes to cancel a transaction.
    event TxCancelVoted(uint256 indexed id, address indexed owner, uint8 votes);
    /// @notice Emitted when an owner withdraws a cancel vote.
    event TxCancelVoteRevoked(uint256 indexed id, address indexed owner, uint8 votes);
    /// @notice Emitted when a transaction becomes canceled.
    event TxCanceled(uint256 indexed id, address indexed owner);
    /// @notice Emitted when a transaction is executed.
    event TxExecuted(uint256 indexed id, address indexed executor, address indexed to, uint256 amount);

    /// @notice Deploys a safe with three fixed owners.
    /// @param _owners Three distinct, non-zero owner addresses.
    /// @dev No Deposit event is emitted for the initial funding. When the safe is deployed through
    /// SaveFactory, msg.sender here is the factory rather than the account that actually sent the
    /// funds, so the event would name the wrong depositor. The deployment transaction itself
    /// already records that transfer.
    constructor(address[3] memory _owners) payable {
        _validateOwners(_owners);
        owners = _owners;
    }

    /// @notice Accepts plain native transfers into the safe.
    /// @dev Zero-value calls are accepted silently; emitting Deposit for them would only add noise
    /// to the event log.
    receive() external payable {
        if (msg.value > 0) {
            emit Deposit(msg.sender, msg.value, address(this).balance);
        }
    }

    /// @dev Reverts unless the caller is one of the three owners.
    function _onlyOwner() internal view {
        if (!isOwner(msg.sender)) revert NotOwner();
    }

    /// @dev Reverts unless the transaction id exists.
    function _validId(uint256 id) internal view {
        if (id >= txs.length) revert BadId();
    }

    /// @notice Whether an address is one of the three owners.
    /// @param a Address to check.
    /// @return True if the address is an owner.
    function isOwner(address a) public view returns (bool) {
        for (uint256 i = 0; i < 3; i++) {
            if (owners[i] == a) return true;
        }
        return false;
    }

    /// @notice Returns the three owners in storage order.
    /// @return The owner addresses.
    function getOwners() external view returns (address[3] memory) {
        return owners;
    }

    /// @notice Total number of transactions ever created.
    /// @return The transaction count.
    function txCount() external view returns (uint256) {
        return txs.length;
    }

    /// @notice Free balance: whatever is not already reserved by created transactions.
    /// @return The spendable balance.
    function availableBalance() external view returns (uint256) {
        uint256 bal = address(this).balance;
        return bal > pendingAmount ? bal - pendingAmount : 0;
    }

    /// @notice Minimal transaction view.
    /// @dev Deprecated: kept only so older frontend builds keep working. Use getTxFull for a
    /// single transaction, or getTxSummaries for lists; getTxs is deprecated as well.
    /// @param id Transaction id.
    /// @return to Recipient address.
    /// @return amount Native value to send.
    /// @return executed Whether the transaction has been executed.
    /// @return confirms Number of confirmations collected.
    /// @return isCanceled Whether the transaction has been canceled.
    function getTx(uint256 id)
        external
        view
        returns (address to, uint256 amount, bool executed, uint8 confirms, bool isCanceled)
    {
        _validId(id);
        Tx storage t = txs[id];
        return (t.to, t.amount, t.executed, t.confirms, canceled[id]);
    }

    /// @notice Full snapshot of a single transaction, calldata included.
    /// @param id Transaction id.
    /// @return The transaction view.
    function getTxFull(uint256 id) external view returns (TxView memory) {
        _validId(id);
        return _txView(id);
    }

    /// @notice Batch read: one RPC call instead of one per entry.
    /// @dev Deprecated for list rendering: each entry carries up to MAX_DATA_LENGTH bytes of
    /// calldata, so a wide range can return hundreds of kilobytes. Prefer getTxSummaries and
    /// fetch calldata per transaction with getTxFull when it is actually needed.
    /// @param from Starting transaction id.
    /// @param count How many entries to return; the tail beyond the array is truncated.
    /// @return The requested transaction views.
    function getTxs(uint256 from, uint256 count) external view returns (TxView[] memory) {
        (uint256 start, uint256 n) = _range(from, count);
        TxView[] memory out = new TxView[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _txView(start + i);
        }
        return out;
    }

    /// @notice Batch read without calldata, for rendering long transaction lists.
    /// @param from Starting transaction id.
    /// @param count How many entries to return; the tail beyond the array is truncated.
    /// @return The requested transaction summaries.
    function getTxSummaries(uint256 from, uint256 count) external view returns (TxSummary[] memory) {
        (uint256 start, uint256 n) = _range(from, count);
        TxSummary[] memory out = new TxSummary[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _txSummary(start + i);
        }
        return out;
    }

    /// @dev Clamps a (from, count) request to the bounds of the transaction array.
    /// The remaining length is computed by subtraction rather than by adding from and count,
    /// so a huge count cannot overflow into a Panic in a public view function.
    function _range(uint256 from, uint256 count) internal view returns (uint256 start, uint256 n) {
        uint256 len = txs.length;
        if (from >= len || count == 0) {
            return (0, 0);
        }
        uint256 remaining = len - from;
        return (from, count < remaining ? count : remaining);
    }

    /// @dev Builds the full view for a transaction id.
    function _txView(uint256 id) internal view returns (TxView memory v) {
        Tx storage t = txs[id];
        v.id = id;
        v.to = t.to;
        v.amount = t.amount;
        v.executed = t.executed;
        v.confirms = t.confirms;
        v.isCanceled = canceled[id];
        v.txProposer = proposer[id];
        v.cancelVoteCount = cancelVotes[id];
        v.createdBlock = t.createdBlock;
        v.executedBlock = t.executedBlock;
        v.confirmedBy = _confirmedBy(id);
        v.data = t.data;
    }

    /// @dev Builds the calldata-free summary for a transaction id.
    function _txSummary(uint256 id) internal view returns (TxSummary memory v) {
        Tx storage t = txs[id];
        v.id = id;
        v.to = t.to;
        v.amount = t.amount;
        v.executed = t.executed;
        v.confirms = t.confirms;
        v.isCanceled = canceled[id];
        v.txProposer = proposer[id];
        v.cancelVoteCount = cancelVotes[id];
        v.createdBlock = t.createdBlock;
        v.executedBlock = t.executedBlock;
        v.confirmedBy = _confirmedBy(id);
        v.dataLength = t.data.length;
    }

    /// @dev Confirmation flags for the three owners, in owners order.
    function _confirmedBy(uint256 id) internal view returns (bool[3] memory) {
        return [confirmed[id][owners[0]], confirmed[id][owners[1]], confirmed[id][owners[2]]];
    }

    /// @notice Whether a specific owner confirmed a specific transaction.
    /// @dev The address is not checked against the owner set: a non-owner simply returns false,
    /// which is indistinguishable from an owner who has not confirmed. Callers that need that
    /// distinction should read getOwners or getConfirms instead.
    /// @param id Transaction id.
    /// @param owner Owner address to check.
    /// @return True if that owner has confirmed.
    function isConfirmed(uint256 id, address owner) external view returns (bool) {
        _validId(id);
        return confirmed[id][owner];
    }

    /// @notice Which of the three owners confirmed, in a single call, in owners order.
    /// @param id Transaction id.
    /// @return Confirmation flags aligned with owners.
    function getConfirms(uint256 id) external view returns (bool[3] memory) {
        _validId(id);
        return _confirmedBy(id);
    }

    /// @notice Creates a plain native transfer.
    /// @dev Kept for compatibility with the current frontend, which does not build calldata.
    /// @param to Recipient address.
    /// @param amount Native value to send.
    /// @return The new transaction id.
    function createTx(address to, uint256 amount) external returns (uint256) {
        return _createTx(to, amount, "");
    }

    /// @notice Creates a transfer with arbitrary calldata, so the safe can call other contracts.
    /// @param to Recipient or target contract.
    /// @param amount Native value to send, may be zero.
    /// @param data Calldata forwarded to the target, up to MAX_DATA_LENGTH bytes.
    /// @return The new transaction id.
    function createTx(address to, uint256 amount, bytes calldata data) external returns (uint256) {
        return _createTx(to, amount, data);
    }

    /// @dev Shared creation path: validates input, reserves the amount, appends the record.
    /// Self-calls are rejected: every state-changing entry point is owner-gated, so a call
    /// from the safe to itself could only ever revert, and forbidding it closes the whole class.
    function _createTx(address to, uint256 amount, bytes memory data) internal returns (uint256) {
        _onlyOwner();
        if (to == address(0)) revert BadRecipient();
        if (to == address(this)) revert BadRecipient();
        if (amount == 0 && data.length == 0) revert EmptyTransaction();
        if (data.length > MAX_DATA_LENGTH) revert DataTooLong();

        uint256 newPending = pendingAmount + amount;
        if (address(this).balance < newPending) revert ExceedsAvailableBalance();
        pendingAmount = newPending;

        txs.push(
            Tx({
                to: to,
                amount: amount,
                executed: false,
                confirms: 0,
                createdBlock: uint64(block.number),
                executedBlock: 0,
                data: data
            })
        );
        uint256 id = txs.length - 1;
        proposer[id] = msg.sender;

        emit TxCreated(id, msg.sender, to, amount);
        return id;
    }

    /// @notice Confirms a pending transaction.
    /// @param id Transaction id.
    function confirmTx(uint256 id) external {
        _onlyOwner();
        _validId(id);

        Tx storage t = txs[id];
        if (t.executed) revert AlreadyExecuted();
        if (canceled[id]) revert TransactionCanceled();
        if (confirmed[id][msg.sender]) revert AlreadyConfirmed();

        confirmed[id][msg.sender] = true;
        t.confirms += 1;

        emit TxConfirmed(id, msg.sender, t.confirms);
    }

    /// @notice Withdraws the caller's confirmation from a pending transaction.
    /// @param id Transaction id.
    function revokeConfirm(uint256 id) external {
        _onlyOwner();
        _validId(id);

        Tx storage t = txs[id];
        if (t.executed) revert AlreadyExecuted();
        if (canceled[id]) revert TransactionCanceled();
        if (!confirmed[id][msg.sender]) revert NotConfirmed();
        // Defensive only: confirmed and confirms are always written together, so a caller that
        // passed the check above necessarily contributed to a non-zero count.
        if (t.confirms == 0) revert NoConfirmations();

        confirmed[id][msg.sender] = false;
        t.confirms -= 1;

        emit TxRevoked(id, msg.sender, t.confirms);
    }

    /// @notice Votes to cancel a pending transaction.
    /// @dev Cancellation requires THRESHOLD owner votes. Exception: the proposer can
    /// cancel their own transaction alone, as long as nobody else has confirmed it.
    /// @param id Transaction id.
    function cancelTx(uint256 id) external {
        _onlyOwner();
        _validId(id);

        Tx storage t = txs[id];
        if (t.executed) revert AlreadyExecuted();
        if (canceled[id]) revert TransactionCanceled();

        if (t.confirms >= THRESHOLD) revert QuorumReached();
        bool soleProposer =
            msg.sender == proposer[id] && (t.confirms == 0 || (t.confirms == 1 && confirmed[id][msg.sender]));

        if (soleProposer) {
            _markCanceled(id, t.amount);
            emit TxCanceled(id, msg.sender);
            return;
        }

        if (cancelVoted[id][msg.sender]) revert AlreadyVotedToCancel();
        cancelVoted[id][msg.sender] = true;
        cancelVotes[id] += 1;

        emit TxCancelVoted(id, msg.sender, cancelVotes[id]);

        if (cancelVotes[id] >= THRESHOLD) {
            _markCanceled(id, t.amount);
            emit TxCanceled(id, msg.sender);
        }
    }

    /// @dev Marks a transaction canceled and frees its reserved amount.
    function _markCanceled(uint256 id, uint256 amount) internal {
        canceled[id] = true;
        _releasePending(amount);
    }

    /// @dev Releases a reserved amount without underflowing.
    function _releasePending(uint256 amount) internal {
        if (amount == 0) return;
        if (pendingAmount >= amount) pendingAmount -= amount;
        else pendingAmount = 0;
    }

    /// @notice Withdraws the caller's cancel vote.
    /// @param id Transaction id.
    function revokeCancelVote(uint256 id) external {
        _onlyOwner();
        _validId(id);

        Tx storage t = txs[id];
        if (t.executed) revert AlreadyExecuted();
        if (canceled[id]) revert TransactionCanceled();
        if (!cancelVoted[id][msg.sender]) revert NotVotedToCancel();
        // Defensive only: cancelVoted and cancelVotes are always written together, so a caller
        // that passed the check above necessarily contributed to a non-zero count.
        if (cancelVotes[id] == 0) revert NoCancelVotes();

        cancelVoted[id][msg.sender] = false;
        cancelVotes[id] -= 1;

        emit TxCancelVoteRevoked(id, msg.sender, cancelVotes[id]);
    }

    /// @notice Executes a transaction that has collected THRESHOLD confirmations.
    /// @dev The executed flag is set before the external call, on top of nonReentrant.
    /// @param id Transaction id.
    function executeTx(uint256 id) external nonReentrant {
        _onlyOwner();
        _validId(id);

        Tx storage t = txs[id];

        if (t.executed) revert AlreadyExecuted();
        if (canceled[id]) revert TransactionCanceled();
        if (t.confirms < THRESHOLD) revert NotEnoughConfirmations();
        if (address(this).balance < t.amount) revert InsufficientBalance();

        t.executed = true;
        t.executedBlock = uint64(block.number);
        _releasePending(t.amount);

        (bool ok,) = payable(t.to).call{value: t.amount}(t.data);
        if (!ok) revert TransferFailed();

        emit TxExecuted(id, msg.sender, t.to, t.amount);
    }
}

/// @title SaveFactory
/// @notice Deploys Save instances and indexes them by owner.
/// @dev The factory embeds the full Save creation code, so Save's size counts
/// against the factory's EIP-170 limit.
contract SaveFactory {
    /// @notice Maximum safe name length, in bytes.
    uint256 public constant MAX_NAME_LENGTH = 32;

    /// @notice Safes indexed by owner address.
    mapping(address => address[]) public safesByOwner;

    /// @dev Optional display name per safe. Read through getSafeName; the automatic
    /// getter is omitted because it would duplicate that function exactly.
    mapping(address => string) internal safeNames;

    /// @notice Owners recorded per safe at creation time.
    mapping(address => address[3]) public safeOwners;

    /// @notice Emitted when a new safe is deployed.
    event SaveCreated(address indexed save, address[3] owners);
    /// @notice Emitted when a safe is renamed.
    event SafeRenamed(address indexed safe, string name);

    /// @notice Deploys a new safe, optionally funding it with the sent value.
    /// @param owners Three distinct, non-zero owner addresses.
    /// @return The address of the new safe.
    function createSave(address[3] memory owners) external payable returns (address) {
        _validateOwners(owners);
        Save s = new Save{value: msg.value}(owners);

        safesByOwner[owners[0]].push(address(s));
        safesByOwner[owners[1]].push(address(s));
        safesByOwner[owners[2]].push(address(s));

        safeOwners[address(s)] = owners;

        emit SaveCreated(address(s), owners);
        return address(s);
    }

    /// @notice All safes an address co-owns.
    /// @param owner Owner address.
    /// @return The safe addresses.
    function getSafesForOwner(address owner) external view returns (address[] memory) {
        return safesByOwner[owner];
    }

    /// @notice The three owners recorded for a safe.
    /// @param safe Safe address.
    /// @return The owner addresses.
    function getSafeOwners(address safe) external view returns (address[3] memory) {
        return safeOwners[safe];
    }

    /// @notice Sets the display name of a safe. Callable by any of its owners.
    /// @dev The limit is measured in bytes, not characters, so multi-byte names are shorter.
    /// @param safe Safe address.
    /// @param name New name, up to MAX_NAME_LENGTH bytes.
    function setSafeName(address safe, string calldata name) external {
        address[3] memory owners = safeOwners[safe];
        if (msg.sender != owners[0] && msg.sender != owners[1] && msg.sender != owners[2]) {
            revert NotOwner();
        }
        if (bytes(name).length > MAX_NAME_LENGTH) revert NameTooLong();
        safeNames[safe] = name;
        emit SafeRenamed(safe, name);
    }

    /// @notice The display name of a safe, empty if unset.
    /// @param safe Safe address.
    /// @return The safe name.
    function getSafeName(address safe) external view returns (string memory) {
        return safeNames[safe];
    }
}
