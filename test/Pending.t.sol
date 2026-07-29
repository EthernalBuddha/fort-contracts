// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import "forge-std/Test.sol";
import "../src/Save.sol";

/// Цель для проверки вызова чужого контракта из сейфа.
contract Target {
    uint256 public pings;
    uint256 public received;

    function ping() external payable {
        pings += 1;
        received += msg.value;
    }
}

contract PendingTest is Test {
    Save save;
    Target target;

    address a = makeAddr("a");
    address b = makeAddr("b");
    address c = makeAddr("c");
    address dest = makeAddr("dest");

    function setUp() public {
        vm.deal(address(this), 100 ether);
        save = new Save{value: 10 ether}([a, b, c]);
        target = new Target();
    }

    // ---------- Учёт обязательств ----------

    // Суммарно нельзя обещать больше, чем лежит на балансе.
    function test_CannotOverCommit() public {
        vm.prank(a);
        save.createTx(dest, 6 ether);

        assertEq(save.pendingAmount(), 6 ether);
        assertEq(save.availableBalance(), 4 ether);

        vm.prank(b);
        vm.expectRevert(ExceedsAvailableBalance.selector);
        save.createTx(dest, 5 ether);
    }

    // Отмена возвращает сумму в свободный баланс.
    function test_CancelReleasesPending() public {
        vm.prank(a);
        uint256 id = save.createTx(dest, 10 ether);
        assertEq(save.availableBalance(), 0);

        vm.prank(a);
        save.cancelTx(id); // автор отменяет в одиночку

        assertEq(save.pendingAmount(), 0);
        assertEq(save.availableBalance(), 10 ether);

        vm.prank(b);
        save.createTx(dest, 10 ether); // снова можно
    }

    // После исполнения обязательство снимается, баланс уменьшается.
    function test_ExecuteReleasesPending() public {
        vm.prank(a);
        uint256 id = save.createTx(dest, 6 ether);

        vm.prank(a);
        save.confirmTx(id);
        vm.prank(b);
        save.confirmTx(id);
        vm.prank(a);
        save.executeTx(id);

        assertEq(dest.balance, 6 ether);
        assertEq(save.pendingAmount(), 0);
        assertEq(address(save).balance, 4 ether);
        assertEq(save.availableBalance(), 4 ether);
    }

    // Отзыв голоса за отмену не освобождает сумму повторно.
    function test_PendingNotDoubleReleased() public {
        vm.prank(a);
        uint256 id = save.createTx(dest, 4 ether);

        vm.prank(b);
        save.cancelTx(id);
        vm.prank(c); // два голоса — отменена
        save.cancelTx(id);

        assertEq(save.pendingAmount(), 0);

        vm.prank(a);
        vm.expectRevert(TransactionCanceled.selector);
        save.cancelTx(id);

        assertEq(save.pendingAmount(), 0);
        assertEq(save.availableBalance(), 10 ether);
    }

    // ---------- Номера блоков ----------

    // Блок создания и блок исполнения записаны — по ним ищется хеш в журнале.
    function test_BlocksRecorded() public {
        vm.roll(1000);

        vm.prank(a);
        uint256 id = save.createTx(dest, 1 ether);

        Save.TxView memory v1 = save.getTxFull(id);
        assertEq(uint256(v1.createdBlock), 1000);
        assertEq(uint256(v1.executedBlock), 0);

        vm.prank(a);
        save.confirmTx(id);
        vm.prank(b);
        save.confirmTx(id);

        vm.roll(1042);
        vm.prank(a);
        save.executeTx(id);

        Save.TxView memory v2 = save.getTxFull(id);
        assertEq(uint256(v2.createdBlock), 1000);
        assertEq(uint256(v2.executedBlock), 1042);
    }

    // ---------- Пакетное чтение ----------

    // getTxs отдаёт всё одним вызовом, включая кто подтвердил.
    function test_GetTxsBatch() public {
        vm.prank(a);
        uint256 id0 = save.createTx(dest, 1 ether);
        vm.prank(b);
        uint256 id1 = save.createTx(dest, 2 ether);
        vm.prank(c);
        save.createTx(dest, 3 ether);

        vm.prank(a);
        save.confirmTx(id1);
        vm.prank(c);
        save.confirmTx(id1);

        Save.TxView[] memory list = save.getTxs(0, 10);
        assertEq(list.length, 3);

        assertEq(list[0].id, id0);
        assertEq(list[0].amount, 1 ether);
        assertEq(list[0].txProposer, a);
        assertEq(list[0].confirms, 0);

        assertEq(list[1].amount, 2 ether);
        assertEq(list[1].confirms, 2);
        assertTrue(list[1].confirmedBy[0]); // a
        assertFalse(list[1].confirmedBy[1]); // b не подтверждал
        assertTrue(list[1].confirmedBy[2]); // c

        assertEq(list[2].amount, 3 ether);
    }

    // Срез и выход за границы не ломают вызов.
    function test_GetTxsBounds() public {
        vm.prank(a);
        save.createTx(dest, 1 ether);
        vm.prank(a);
        save.createTx(dest, 1 ether);

        assertEq(save.getTxs(1, 5).length, 1);
        assertEq(save.getTxs(5, 5).length, 0);
        assertEq(save.getTxs(0, 0).length, 0);
    }

    // getConfirms возвращает три флага в порядке owners.
    function test_GetConfirms() public {
        vm.prank(a);
        uint256 id = save.createTx(dest, 1 ether);

        vm.prank(b);
        save.confirmTx(id);

        bool[3] memory f = save.getConfirms(id);
        assertFalse(f[0]);
        assertTrue(f[1]);
        assertFalse(f[2]);
    }

    // ---------- Вызов чужого контракта ----------

    // Сейф вызывает функцию другого контракта и передаёт средства.
    function test_ContractCallWithData() public {
        bytes memory data = abi.encodeWithSignature("ping()");

        vm.prank(a);
        uint256 id = save.createTx(address(target), 1 ether, data);

        vm.prank(a);
        save.confirmTx(id);
        vm.prank(b);
        save.confirmTx(id);
        vm.prank(a);
        save.executeTx(id);

        assertEq(target.pings(), 1);
        assertEq(target.received(), 1 ether);
        assertEq(address(target).balance, 1 ether);
    }

    // Вызов без перевода средств допустим и не занимает баланс.
    function test_ZeroValueCallAllowed() public {
        bytes memory data = abi.encodeWithSignature("ping()");

        vm.prank(a);
        uint256 id = save.createTx(address(target), 0, data);

        assertEq(save.pendingAmount(), 0);

        vm.prank(a);
        save.confirmTx(id);
        vm.prank(b);
        save.confirmTx(id);
        vm.prank(a);
        save.executeTx(id);

        assertEq(target.pings(), 1);
        assertEq(target.received(), 0);
    }

    // Пустая транзакция — ни суммы, ни вызова — отклоняется.
    function test_EmptyTxReverts() public {
        vm.prank(a);
        vm.expectRevert(EmptyTransaction.selector);
        save.createTx(dest, 0, "");
    }

    // Лимит длины calldata работает.
    function test_DataTooLongReverts() public {
        bytes memory big = new bytes(4097);

        vm.prank(a);
        vm.expectRevert(DataTooLong.selector);
        save.createTx(dest, 1 ether, big);
    }

    // Граница лимита проходит.
    function test_DataAtLimitAccepted() public {
        bytes memory big = new bytes(4096);

        vm.prank(a);
        uint256 id = save.createTx(dest, 1 ether, big);

        Save.TxView memory v = save.getTxFull(id);
        assertEq(v.data.length, 4096);
    }

    // Чужой не создаёт транзакции через новую перегрузку.
    function test_NonOwnerCannotCreateWithData() public {
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(NotOwner.selector);
        save.createTx(dest, 1 ether, abi.encodeWithSignature("ping()"));
    }
}
