// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import "forge-std/Test.sol";
import "../src/Save.sol";

/// @dev Covers the guards added alongside the Deposit and _range fixes.
/// Every test here fails on the previous revision of Save.sol.
contract GuardsTest is Test {
    Save save;
    address a;
    address b;
    address c;

    function setUp() public {
        a = makeAddr("a");
        b = makeAddr("b");
        c = makeAddr("c");
        save = new Save{value: 10 ether}([a, b, c]);
    }

    // A count larger than the remaining range must be clamped, not added to `from`.
    // On the previous revision `from + count` overflowed and reverted with Panic 0x11.
    function test_GetTxsHugeCountDoesNotPanic() public {
        vm.prank(a);
        save.createTx(makeAddr("dest0"), 1 ether);
        vm.prank(a);
        save.createTx(makeAddr("dest1"), 1 ether);

        Save.TxView[] memory tail = save.getTxs(1, type(uint256).max);
        assertEq(tail.length, 1);
        assertEq(tail[0].id, 1);

        Save.TxSummary[] memory all = save.getTxSummaries(0, type(uint256).max);
        assertEq(all.length, 2);

        // Out-of-range start still yields an empty slice rather than a revert.
        assertEq(save.getTxSummaries(2, type(uint256).max).length, 0);
    }

    // A zero-value plain transfer is accepted but must not emit Deposit.
    function test_ZeroValueTransferEmitsNoDeposit() public {
        vm.recordLogs();
        (bool ok,) = payable(address(save)).call{value: 0}("");
        assertTrue(ok);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // A funded plain transfer still emits exactly one Deposit.
    function test_FundedTransferEmitsDeposit() public {
        vm.deal(a, 1 ether);

        vm.recordLogs();
        vm.prank(a);
        (bool ok,) = payable(address(save)).call{value: 1 ether}("");
        assertTrue(ok);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);
        assertEq(entries[0].topics[0], keccak256("Deposit(address,uint256,uint256)"));
    }

    // Funding at construction must emit nothing: msg.sender there is the deployer,
    // which is the factory in production and would misname the depositor.
    function test_ConstructorEmitsNoDeposit() public {
        vm.recordLogs();
        Save fresh = new Save{value: 1 ether}([a, b, c]);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(address(fresh).balance, 1 ether);
    }
}
