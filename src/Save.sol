// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

abstract contract ReentrancyGuard {
    uint256 private _status;

    constructor() {
        _status = 1;
    }

    modifier nonReentrant() {
        require(_status == 1, "reentrant");
        _status = 2;
        _;
        _status = 1;
    }
}

contract Save is ReentrancyGuard {
    uint8 public constant THRESHOLD = 2;
    uint256 public constant MAX_DATA_LENGTH = 4096;

    address[3] public owners;

    struct Tx {
        address to;
        uint256 amount;
        bool executed;
        uint8 confirms;
        uint64 createdBlock;
        uint64 executedBlock;
        bytes data;
    }

    /// Читается через getTx / getTxFull / getTxs — публичного геттера нет намеренно.
    Tx[] internal txs;

    mapping(uint256 => mapping(address => bool)) public confirmed;
    mapping(uint256 => bool) public canceled;

    mapping(uint256 => address) public proposer;
    mapping(uint256 => uint8) public cancelVotes;
    mapping(uint256 => mapping(address => bool)) public cancelVoted;

    /// Сумма amount по всем созданным, но не исполненным и не отменённым транзакциям.
    /// Не даёт создать обязательств больше, чем есть на балансе.
    uint256 public pendingAmount;

    /// Плоский снимок транзакции для чтения одним вызовом.
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

    event Deposit(address indexed from, uint256 amount, uint256 balance);
    event TxCreated(uint256 indexed id, address indexed proposer, address indexed to, uint256 amount);
    event TxConfirmed(uint256 indexed id, address indexed owner, uint8 confirms);
    event TxRevoked(uint256 indexed id, address indexed owner, uint8 confirms);
    event TxCancelVoted(uint256 indexed id, address indexed owner, uint8 votes);
    event TxCancelVoteRevoked(uint256 indexed id, address indexed owner, uint8 votes);
    event TxCanceled(uint256 indexed id, address indexed owner);
    event TxExecuted(uint256 indexed id, address indexed executor, address indexed to, uint256 amount);

    constructor(address[3] memory _owners) payable {
        _validateOwners(_owners);
        owners = _owners;
        if (msg.value > 0) {
            emit Deposit(msg.sender, msg.value, address(this).balance);
        }
    }

    receive() external payable {
        emit Deposit(msg.sender, msg.value, address(this).balance);
    }

    function _validateOwners(address[3] memory o) internal pure {
        require(o[0] != address(0) && o[1] != address(0) && o[2] != address(0), "zero owner");
        require(o[0] != o[1] && o[0] != o[2] && o[1] != o[2], "owners must differ");
    }

    function isOwner(address a) public view returns (bool) {
        for (uint256 i = 0; i < 3; i++) {
            if (owners[i] == a) return true;
        }
        return false;
    }

    function getOwners() external view returns (address[3] memory) {
        return owners;
    }

    function txCount() external view returns (uint256) {
        return txs.length;
    }

    /// Свободный баланс: то, что ещё не обещано созданным транзакциям.
    function availableBalance() external view returns (uint256) {
        uint256 bal = address(this).balance;
        return bal > pendingAmount ? bal - pendingAmount : 0;
    }

    /// Прежняя сигнатура — сохранена, чтобы не ломать существующий фронт.
    function getTx(uint256 id)
        external
        view
        returns (address to, uint256 amount, bool executed, uint8 confirms_, bool isCanceled)
    {
        require(id < txs.length, "bad id");
        Tx storage t = txs[id];
        return (t.to, t.amount, t.executed, t.confirms, canceled[id]);
    }

    function getTxFull(uint256 id) external view returns (TxView memory) {
        require(id < txs.length, "bad id");
        return _txView(id);
    }

    /// Пакетное чтение: одна транзакция RPC вместо одной на каждую запись.
    /// from — начальный id, count — сколько вернуть. Хвост за пределами массива обрезается.
    function getTxs(uint256 from, uint256 count) external view returns (TxView[] memory) {
        uint256 len = txs.length;
        if (from >= len || count == 0) {
            return new TxView[](0);
        }
        uint256 end = from + count;
        if (end > len) end = len;
        uint256 n = end - from;

        TxView[] memory out = new TxView[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _txView(from + i);
        }
        return out;
    }

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
        v.confirmedBy = [
            confirmed[id][owners[0]],
            confirmed[id][owners[1]],
            confirmed[id][owners[2]]
        ];
        v.data = t.data;
    }

    function isConfirmed(uint256 id, address owner) external view returns (bool) {
        require(id < txs.length, "bad id");
        return confirmed[id][owner];
    }

    /// Кто из трёх владельцев подтвердил — одним вызовом, в порядке owners.
    function getConfirms(uint256 id) external view returns (bool[3] memory) {
        require(id < txs.length, "bad id");
        return [
            confirmed[id][owners[0]],
            confirmed[id][owners[1]],
            confirmed[id][owners[2]]
        ];
    }

    /// Простой перевод. Оставлено для совместимости с текущим фронтом.
    function createTx(address to, uint256 amount) external returns (uint256) {
        return _createTx(to, amount, "");
    }

    /// Перевод с произвольным calldata — сейф может вызывать другие контракты.
    function createTx(address to, uint256 amount, bytes calldata data) external returns (uint256) {
        return _createTx(to, amount, data);
    }

    function _createTx(address to, uint256 amount, bytes memory data) internal returns (uint256) {
        require(isOwner(msg.sender), "not owner");
        require(to != address(0), "bad to");
        require(amount > 0 || data.length > 0, "empty tx");
        require(data.length <= MAX_DATA_LENGTH, "data too long");

        uint256 newPending = pendingAmount + amount;
        require(address(this).balance >= newPending, "exceeds available balance");
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

    function confirmTx(uint256 id) external {
        require(isOwner(msg.sender), "not owner");
        require(id < txs.length, "bad id");

        Tx storage t = txs[id];
        require(!t.executed, "done");
        require(!canceled[id], "canceled");
        require(!confirmed[id][msg.sender], "already confirmed");

        confirmed[id][msg.sender] = true;
        t.confirms += 1;

        emit TxConfirmed(id, msg.sender, t.confirms);
    }

    function revokeConfirm(uint256 id) external {
        require(isOwner(msg.sender), "not owner");
        require(id < txs.length, "bad id");

        Tx storage t = txs[id];
        require(!t.executed, "done");
        require(!canceled[id], "canceled");
        require(confirmed[id][msg.sender], "not confirmed");
        require(t.confirms > 0, "no confirms");

        confirmed[id][msg.sender] = false;
        t.confirms -= 1;

        emit TxRevoked(id, msg.sender, t.confirms);
    }

    /// Отмена требует THRESHOLD голосов владельцев.
    /// Исключение: автор отменяет свою транзакцию в одиночку,
    /// пока её не подтвердил никто, кроме него самого.
    function cancelTx(uint256 id) external {
        require(isOwner(msg.sender), "not owner");
        require(id < txs.length, "bad id");

        Tx storage t = txs[id];
        require(!t.executed, "done");
        require(!canceled[id], "already canceled");

        bool soleProposer =
            msg.sender == proposer[id] &&
            (t.confirms == 0 || (t.confirms == 1 && confirmed[id][msg.sender]));

        if (soleProposer) {
            _markCanceled(id, t.amount);
            emit TxCanceled(id, msg.sender);
            return;
        }

        require(!cancelVoted[id][msg.sender], "already voted");
        cancelVoted[id][msg.sender] = true;
        cancelVotes[id] += 1;

        emit TxCancelVoted(id, msg.sender, cancelVotes[id]);

        if (cancelVotes[id] >= THRESHOLD) {
            _markCanceled(id, t.amount);
            emit TxCanceled(id, msg.sender);
        }
    }

    function _markCanceled(uint256 id, uint256 amount) internal {
        canceled[id] = true;
        _releasePending(amount);
    }

    function _releasePending(uint256 amount) internal {
        if (amount == 0) return;
        if (pendingAmount >= amount) pendingAmount -= amount;
        else pendingAmount = 0;
    }

    function revokeCancelVote(uint256 id) external {
        require(isOwner(msg.sender), "not owner");
        require(id < txs.length, "bad id");

        Tx storage t = txs[id];
        require(!t.executed, "done");
        require(!canceled[id], "canceled");
        require(cancelVoted[id][msg.sender], "not voted");
        require(cancelVotes[id] > 0, "no votes");

        cancelVoted[id][msg.sender] = false;
        cancelVotes[id] -= 1;

        emit TxCancelVoteRevoked(id, msg.sender, cancelVotes[id]);
    }

    function executeTx(uint256 id) external nonReentrant {
        require(isOwner(msg.sender), "not owner");
        require(id < txs.length, "bad id");

        Tx storage t = txs[id];

        require(!t.executed, "done");
        require(!canceled[id], "canceled");
        require(t.confirms >= THRESHOLD, "need 2 confirmations");
        require(address(this).balance >= t.amount, "insufficient balance");

        t.executed = true;
        t.executedBlock = uint64(block.number);
        _releasePending(t.amount);

        (bool ok, ) = payable(t.to).call{value: t.amount}(t.data);
        require(ok, "transfer failed");

        emit TxExecuted(id, msg.sender, t.to, t.amount);
    }
}

contract SaveFactory {
    uint256 public constant MAX_NAME_LENGTH = 32;

    mapping(address => address[]) public safesByOwner;
    mapping(address => string) public safeNames;
    mapping(address => address[3]) public safeOwners;

    event SaveCreated(address indexed save, address[3] owners);
    event SafeRenamed(address indexed safe, string name);

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

    function getSafesForOwner(address owner) external view returns (address[] memory) {
        return safesByOwner[owner];
    }

    function getSafeOwners(address safe) external view returns (address[3] memory) {
        return safeOwners[safe];
    }

    function setSafeName(address safe, string calldata name) external {
        address[3] memory owners = safeOwners[safe];
        require(
            msg.sender == owners[0] || msg.sender == owners[1] || msg.sender == owners[2],
            "not owner"
        );
        require(bytes(name).length <= MAX_NAME_LENGTH, "name too long");
        safeNames[safe] = name;
        emit SafeRenamed(safe, name);
    }

    function getSafeName(address safe) external view returns (string memory) {
        return safeNames[safe];
    }

    function _validateOwners(address[3] memory o) internal pure {
        require(o[0] != address(0) && o[1] != address(0) && o[2] != address(0), "zero owner");
        require(o[0] != o[1] && o[0] != o[2] && o[1] != o[2], "owners must differ");
    }
}
