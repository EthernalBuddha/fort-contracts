// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import "forge-std/Test.sol";
import "../src/Save.sol";

/// Recipient that always rejects incoming native currency, so executeTx can never succeed.
contract RevertingReceiver {
    receive() external payable {
        revert("recipient refuses funds");
    }
}

/// An owner that is a contract and tries to re-enter executeTx from its receive hook.
/// The re-entrant call is wrapped in try/catch so the outer execution still completes:
/// that way the test can assert the guard fired instead of only seeing a bubbled revert.
contract ReentrantOwner {
    Save public save;
    uint256 public txId;
    bool public attempted;
    bool public reentered;
    bool public blocked;

    function setSave(Save s) external {
        save = s;
    }

    function propose(address to, uint256 amount) external returns (uint256) {
        txId = save.createTx(to, amount);
        save.confirmTx(txId);
        return txId;
    }

    receive() external payable {
        if (attempted) return;
        attempted = true;
        try save.executeTx(txId) {
            reentered = true;
        } catch {
            blocked = true;
        }
    }
}

contract ReentrancyTest is Test {
    Save save;
    address a = makeAddr("a");
    address b = makeAddr("b");
    address c = makeAddr("c");
    address dest = makeAddr("dest");

    function setUp() public {
        vm.deal(address(this), 100 ether);
        save = new Save{value: 10 ether}([a, b, c]);
    }

    // ---------- Stuck reservation ----------

    // A recipient that reverts on receive locks its amount in pendingAmount: the transfer can
    // never execute, and while the quorum holds it cannot be canceled either. The documented way
    // out is revokeConfirm followed by cancelTx, which releases the reservation.
    function test_RevertingRecipientLocksFundsUntilCancel() public {
        RevertingReceiver bad = new RevertingReceiver();

        vm.prank(a);
        uint256 id = save.createTx(address(bad), 1 ether);
        vm.prank(a);
        save.confirmTx(id);
        vm.prank(b);
        save.confirmTx(id);

        assertEq(save.pendingAmount(), 1 ether, "amount not reserved");
        assertEq(save.availableBalance(), 9 ether, "available balance not reduced");

        vm.prank(a);
        vm.expectRevert(TransferFailed.selector);
        save.executeTx(id);

        // The failed execution changed nothing: the reservation is still held.
        assertEq(save.pendingAmount(), 1 ether, "reservation released by failed execution");
        assertEq(save.availableBalance(), 9 ether, "available balance changed unexpectedly");
        assertEq(address(save).balance, 10 ether, "funds left the safe");

        // With THRESHOLD confirmations in place the transaction cannot be canceled.
        vm.prank(c);
        vm.expectRevert(QuorumReached.selector);
        save.cancelTx(id);

        // One confirming owner steps back, dropping the count below THRESHOLD.
        vm.prank(b);
        save.revokeConfirm(id);

        // The proposer now holds the only confirmation, so it can cancel on its own.
        vm.prank(a);
        save.cancelTx(id);

        assertTrue(save.canceled(id), "transaction not canceled");
        assertEq(save.pendingAmount(), 0, "reservation not released");
        assertEq(save.availableBalance(), 10 ether, "available balance not restored");
    }

    // ---------- Reentrancy ----------

    // An owner contract that re-enters executeTx while receiving funds must not get paid twice.
    // Two independent defences apply: the executed flag is written before the external call, and
    // nonReentrant blocks the nested entry outright.
    function test_ReentrantOwnerCannotDrainSafe() public {
        ReentrantOwner attacker = new ReentrantOwner();
        Save guarded = new Save{value: 10 ether}([address(attacker), b, c]);
        attacker.setSave(guarded);

        uint256 id = attacker.propose(address(attacker), 1 ether);

        vm.prank(b);
        guarded.confirmTx(id);

        vm.prank(b);
        guarded.executeTx(id);

        assertTrue(attacker.attempted(), "receive hook never ran");
        assertTrue(attacker.blocked(), "nested executeTx was not rejected");
        assertFalse(attacker.reentered(), "nested executeTx succeeded");
        assertEq(address(attacker).balance, 1 ether, "attacker received the wrong amount");
        assertEq(address(guarded).balance, 9 ether, "safe paid out more than once");
        assertEq(guarded.pendingAmount(), 0, "reservation not released");
    }

    // ---------- Recipient validation ----------

    // The zero address is rejected: funds sent there would be unrecoverable.
    function test_ZeroRecipientRejected() public {
        vm.prank(a);
        vm.expectRevert(BadRecipient.selector);
        save.createTx(address(0), 1 ether);
    }

    // The safe cannot target itself: every state-changing entry point is owner-gated, so such a
    // call could only ever revert.
    function test_SafeCannotTargetItself() public {
        vm.prank(a);
        vm.expectRevert(BadRecipient.selector);
        save.createTx(address(save), 1 ether);
    }

    // ---------- Execution guards ----------

    // One confirmation out of the required two is not enough to execute.
    function test_ExecuteNeedsTwoConfirmations() public {
        vm.prank(a);
        uint256 id = save.createTx(dest, 1 ether);
        vm.prank(a);
        save.confirmTx(id);

        vm.prank(a);
        vm.expectRevert(NotEnoughConfirmations.selector);
        save.executeTx(id);
    }

    // A transaction pays out exactly once, even if an owner calls executeTx again.
    function test_CannotExecuteTwice() public {
        vm.prank(a);
        uint256 id = save.createTx(dest, 1 ether);
        vm.prank(a);
        save.confirmTx(id);
        vm.prank(b);
        save.confirmTx(id);

        vm.prank(a);
        save.executeTx(id);
        assertEq(dest.balance, 1 ether, "recipient not paid");

        vm.prank(b);
        vm.expectRevert(AlreadyExecuted.selector);
        save.executeTx(id);

        assertEq(dest.balance, 1 ether, "recipient paid twice");
        assertEq(address(save).balance, 9 ether, "safe balance wrong");
    }
}
