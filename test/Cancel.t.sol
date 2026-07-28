// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import "forge-std/Test.sol";
import "../src/Save.sol";

contract CancelTest is Test {
    Save save;
    address a = makeAddr("a");
    address b = makeAddr("b");
    address c = makeAddr("c");
    address dest = makeAddr("dest");

    function setUp() public {
        vm.deal(address(this), 100 ether);
        save = new Save{value: 10 ether}([a, b, c]);
    }

    // A single owner out of three cannot veto a transaction the others agree on.
    function test_SingleOwnerCannotVeto() public {
        vm.prank(a);
        uint256 id = save.createTx(dest, 1 ether);

        vm.prank(a);
        save.confirmTx(id);

        vm.prank(c); // one cancel vote is not enough
        save.cancelTx(id);

        vm.prank(b); // the quorum still forms
        save.confirmTx(id);

        vm.prank(a);
        save.executeTx(id);

        assertEq(dest.balance, 1 ether);
    }

    // Two owners out of three cancel a transaction before it reaches the quorum.
    function test_TwoOwnersCanCancel() public {
        vm.prank(a);
        uint256 id = save.createTx(dest, 1 ether);

        vm.prank(a);
        save.confirmTx(id);

        vm.prank(c);
        save.cancelTx(id);
        vm.prank(b);
        save.cancelTx(id);

        vm.prank(a);
        vm.expectRevert(TransactionCanceled.selector);
        save.executeTx(id);
    }

    // Once THRESHOLD confirmations are in, cancellation is closed for good.
    // This is the race that used to let cancelTx and executeTx compete for the same state.
    function test_CancelBlockedAfterQuorum() public {
        vm.prank(a);
        uint256 id = save.createTx(dest, 1 ether);

        vm.prank(a);
        save.confirmTx(id);
        vm.prank(b);
        save.confirmTx(id);

        vm.prank(c);
        vm.expectRevert(QuorumReached.selector);
        save.cancelTx(id);

        vm.prank(a);
        save.executeTx(id);

        assertEq(dest.balance, 1 ether);
    }

    // The proposer cancels their own transaction alone while nobody else has backed it.
    function test_ProposerCancelsAlone() public {
        vm.prank(a);
        uint256 id = save.createTx(dest, 1 ether);

        vm.prank(a);
        save.cancelTx(id);

        vm.prank(a);
        vm.expectRevert(TransactionCanceled.selector);
        save.confirmTx(id);
    }

    // A cancel vote can be withdrawn, so cancellation is not a one-way door.
    function test_CancelVoteCanBeRevoked() public {
        vm.prank(a);
        uint256 id = save.createTx(dest, 1 ether);

        vm.prank(a);
        save.confirmTx(id);

        vm.prank(c);
        save.cancelTx(id);
        vm.prank(c);
        save.revokeCancelVote(id);

        vm.prank(b); // one vote again, not enough
        save.cancelTx(id);

        vm.prank(c); // the quorum forms despite the outstanding cancel vote
        save.confirmTx(id);

        vm.prank(a);
        save.executeTx(id);

        assertEq(dest.balance, 1 ether);
    }
}
