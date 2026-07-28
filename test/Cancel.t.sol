// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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

    // Один владелец из трёх больше не может заветировать согласованную транзакцию.
    function test_SingleOwnerCannotVeto() public {
        vm.prank(a);
        uint256 id = save.createTx(dest, 1 ether);

        vm.prank(a); save.confirmTx(id);
        vm.prank(b); save.confirmTx(id);

        vm.prank(c); save.cancelTx(id);   // один голос за отмену — мало

        vm.prank(a);
        save.executeTx(id);

        assertEq(dest.balance, 1 ether);
    }

    // Двое из трёх отменяют.
    function test_TwoOwnersCanCancel() public {
        vm.prank(a);
        uint256 id = save.createTx(dest, 1 ether);

        vm.prank(a); save.confirmTx(id);
        vm.prank(b); save.confirmTx(id);

        vm.prank(c); save.cancelTx(id);
        vm.prank(b); save.cancelTx(id);

        vm.prank(a);
        vm.expectRevert("canceled");
        save.executeTx(id);
    }

    // Автор отменяет свою транзакцию в одиночку, пока её никто не поддержал.
    function test_ProposerCancelsAlone() public {
        vm.prank(a);
        uint256 id = save.createTx(dest, 1 ether);

        vm.prank(a); save.cancelTx(id);

        vm.prank(a);
        vm.expectRevert("canceled");
        save.confirmTx(id);
    }

    // Голос за отмену можно отозвать — отмена не необратима.
    function test_CancelVoteCanBeRevoked() public {
        vm.prank(a);
        uint256 id = save.createTx(dest, 1 ether);

        vm.prank(a); save.confirmTx(id);
        vm.prank(b); save.confirmTx(id);

        vm.prank(c); save.cancelTx(id);
        vm.prank(c); save.revokeCancelVote(id);

        vm.prank(b); save.cancelTx(id);   // снова только один голос

        vm.prank(a);
        save.executeTx(id);

        assertEq(dest.balance, 1 ether);
    }
}
