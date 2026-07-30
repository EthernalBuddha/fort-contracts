// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import "forge-std/Test.sol";
import "../src/Save.sol";

/// @title Parity between getTxSummaries and getTxFull
/// @notice The frontend renders lists from getTxSummaries and details from
///         getTxFull. Any drift between the two structs shows up as wrong data
///         on screen, so every shared field is compared entry by entry.
contract SummariesTest is Test {
    Save save;

    address a;
    address b;
    address c;
    address recipient;

    function setUp() public {
        a = makeAddr("ownerA");
        b = makeAddr("ownerB");
        c = makeAddr("ownerC");
        recipient = makeAddr("recipient");

        save = new Save{value: 10 ether}([a, b, c]);

        // TX 0: plain transfer, fully confirmed and executed.
        vm.prank(a);
        uint256 id0 = save.createTx(recipient, 1 ether);
        vm.prank(a);
        save.confirmTx(id0);
        vm.prank(b);
        save.confirmTx(id0);
        vm.prank(a);
        save.executeTx(id0);

        // Move forward so createdBlock differs between entries.
        vm.roll(block.number + 5);

        // TX 1: carries calldata, one confirmation, one cancel vote, still open.
        vm.prank(a);
        uint256 id1 = save.createTx(recipient, 2 ether, hex"deadbeefcafe");
        vm.prank(b);
        save.confirmTx(id1);
        vm.prank(c);
        save.cancelTx(id1);

        vm.roll(block.number + 5);

        // TX 2: canceled by two votes.
        vm.prank(a);
        uint256 id2 = save.createTx(recipient, 3 ether);
        vm.prank(b);
        save.confirmTx(id2);
        vm.prank(b);
        save.cancelTx(id2);
        vm.prank(c);
        save.cancelTx(id2);

        vm.roll(block.number + 5);

        // TX 3: untouched after creation, all flags at their defaults.
        vm.prank(c);
        save.createTx(recipient, 4 ether);
    }

    /// @dev Compares one summary against the authoritative full view.
    function _assertParity(uint256 id) internal view {
        Save.TxSummary[] memory s = save.getTxSummaries(id, 1);
        assertEq(s.length, 1, "one summary expected");

        Save.TxView memory f = save.getTxFull(id);

        assertEq(s[0].id, f.id, "id");
        assertEq(s[0].to, f.to, "to");
        assertEq(s[0].amount, f.amount, "amount");
        assertEq(s[0].executed, f.executed, "executed");
        assertEq(uint256(s[0].confirms), uint256(f.confirms), "confirms");
        assertEq(s[0].isCanceled, f.isCanceled, "isCanceled");
        assertEq(s[0].txProposer, f.txProposer, "txProposer");
        assertEq(uint256(s[0].cancelVoteCount), uint256(f.cancelVoteCount), "cancelVoteCount");
        assertEq(uint256(s[0].createdBlock), uint256(f.createdBlock), "createdBlock");
        assertEq(uint256(s[0].executedBlock), uint256(f.executedBlock), "executedBlock");
        for (uint256 i = 0; i < 3; i++) {
            assertEq(s[0].confirmedBy[i], f.confirmedBy[i], "confirmedBy");
        }
        assertEq(s[0].dataLength, f.data.length, "dataLength");
    }

    /// @notice Every field of every transaction matches between the two getters.
    function test_SummaryMatchesFullView() public view {
        assertEq(save.txCount(), 4, "four transactions expected");
        for (uint256 id = 0; id < 4; id++) {
            _assertParity(id);
        }
    }

    /// @notice The fixture actually exercises non-default field values, so the
    ///         parity check above cannot pass on all-zero data.
    function test_FixtureCoversNonDefaultFields() public view {
        Save.TxSummary[] memory s = save.getTxSummaries(0, 4);

        assertTrue(s[0].executed, "tx0 executed");
        assertTrue(s[0].executedBlock > 0, "tx0 executedBlock");
        assertEq(s[0].dataLength, 0, "tx0 has no calldata");

        assertEq(s[1].dataLength, 6, "tx1 calldata length");
        assertEq(uint256(s[1].cancelVoteCount), 1, "tx1 one cancel vote");
        assertFalse(s[1].isCanceled, "tx1 still open");

        assertTrue(s[2].isCanceled, "tx2 canceled");
        assertEq(uint256(s[2].cancelVoteCount), 2, "tx2 two cancel votes");

        assertEq(uint256(s[3].confirms), 0, "tx3 unconfirmed");
        assertEq(uint256(s[3].executedBlock), 0, "tx3 not executed");
        assertTrue(s[3].createdBlock > s[0].createdBlock, "createdBlock advances");
    }

    /// @notice Batch reads agree pairwise, not only through single-entry calls.
    function test_BatchReadsAgree() public view {
        Save.TxSummary[] memory s = save.getTxSummaries(1, 3);
        Save.TxView[] memory v = save.getTxs(1, 3);

        assertEq(s.length, v.length, "batch lengths");
        for (uint256 i = 0; i < s.length; i++) {
            assertEq(s[i].id, v[i].id, "batch id");
            assertEq(s[i].to, v[i].to, "batch to");
            assertEq(s[i].amount, v[i].amount, "batch amount");
            assertEq(s[i].dataLength, v[i].data.length, "batch dataLength");
        }
    }

    /// @notice Slice clamping behaves identically in both batch getters.
    function test_RangeClampingMatches() public view {
        assertEq(save.getTxSummaries(0, 100).length, 4, "count clamped to txCount");
        assertEq(save.getTxs(0, 100).length, 4, "count clamped to txCount");

        assertEq(save.getTxSummaries(2, 10).length, 2, "tail clamped");
        assertEq(save.getTxs(2, 10).length, 2, "tail clamped");

        assertEq(save.getTxSummaries(4, 5).length, 0, "out of range is empty");
        assertEq(save.getTxs(4, 5).length, 0, "out of range is empty");

        assertEq(save.getTxSummaries(0, 0).length, 0, "zero count is empty");
    }
}
