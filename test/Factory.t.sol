// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import "forge-std/Test.sol";
import "../src/Save.sol";

contract FactoryTest is Test {
    SaveFactory f;
    address a = makeAddr("a");
    address b = makeAddr("b");
    address c = makeAddr("c");

    function setUp() public {
        f = new SaveFactory();
    }

    // Длинное имя больше не принимается.
    function test_LongSafeNameReverts() public {
        address safe = f.createSave([a, b, c]);

        string memory long = new string(10_000);

        vm.prank(a);
        vm.expectRevert(NameTooLong.selector);
        f.setSafeName(safe, long);
    }

    // Имя ровно на границе проходит.
    function test_NameAtLimitAccepted() public {
        address safe = f.createSave([a, b, c]);

        string memory name = new string(32);

        vm.prank(a);
        f.setSafeName(safe, name);

        assertEq(bytes(f.getSafeName(safe)).length, 32);
    }

    // Чужой не может переименовать сейф.
    function test_NonOwnerCannotRename() public {
        address safe = f.createSave([a, b, c]);
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(NotOwner.selector);
        f.setSafeName(safe, "hack");
    }

    // ---------------------------------------------------------------------
    // Пагинация списка сейфов
    // ---------------------------------------------------------------------

    /// @dev Создаёт n сейфов с одной и той же тройкой владельцев и возвращает
    /// их адреса в порядке создания.
    function _createSafes(uint256 n) internal returns (address[] memory) {
        address[] memory made = new address[](n);
        for (uint256 i; i < n; i++) {
            made[i] = f.createSave([a, b, c]);
        }
        return made;
    }

    // Счётчик совпадает с длиной полного списка.
    function test_SafesCountMatchesFullList() public {
        assertEq(f.safesCountForOwner(a), 0);

        _createSafes(3);

        assertEq(f.safesCountForOwner(a), 3);
        assertEq(f.safesCountForOwner(a), f.getSafesForOwner(a).length);
    }

    // Владелец без сейфов: пустой список, без реверта.
    // Не view: makeAddr вызывает vm.label, а это запись в состояние.
    function test_PagedEmptyForUnknownOwner() public {
        address stranger = makeAddr("stranger");

        assertEq(f.safesCountForOwner(stranger), 0);
        assertEq(f.getSafesForOwnerPaged(stranger, 0, 10).length, 0);
    }

    // offset за концом списка обрезается до пустого результата, а не панику.
    function test_PagedOffsetBeyondEndReturnsEmpty() public {
        _createSafes(3);

        assertEq(f.getSafesForOwnerPaged(a, 3, 10).length, 0);
        assertEq(f.getSafesForOwnerPaged(a, 1000, 10).length, 0);
    }

    // Нулевой limit возвращает пустой список.
    function test_PagedZeroLimitReturnsEmpty() public {
        _createSafes(3);

        assertEq(f.getSafesForOwnerPaged(a, 0, 0).length, 0);
    }

    // limit больше остатка обрезается по фактическому концу списка.
    function test_PagedLimitClampedToRemainder() public {
        address[] memory made = _createSafes(3);

        address[] memory tail = f.getSafesForOwnerPaged(a, 1, 100);

        assertEq(tail.length, 2);
        assertEq(tail[0], made[1]);
        assertEq(tail[1], made[2]);
    }

    // Одна страница, покрывающая весь список, совпадает с полным чтением.
    function test_PagedFullWindowMatchesFullList() public {
        address[] memory made = _createSafes(3);

        address[] memory page = f.getSafesForOwnerPaged(a, 0, 3);
        address[] memory all = f.getSafesForOwner(a);

        assertEq(page.length, all.length);
        for (uint256 i; i < all.length; i++) {
            assertEq(page[i], all[i]);
            assertEq(page[i], made[i]);
        }
    }

    // Главная проверка: чтение страницами по 2 склеивается в исходный список
    // без потерь и дубликатов.
    function test_PagedPagesConcatenateToFullList() public {
        _createSafes(5);

        address[] memory all = f.getSafesForOwner(a);
        assertEq(all.length, 5);

        uint256 pageSize = 2;
        uint256 seen;

        for (uint256 offset; offset < all.length; offset += pageSize) {
            address[] memory page = f.getSafesForOwnerPaged(a, offset, pageSize);

            uint256 expected = all.length - offset;
            if (expected > pageSize) expected = pageSize;
            assertEq(page.length, expected, "unexpected page size");

            for (uint256 i; i < page.length; i++) {
                assertEq(page[i], all[offset + i], "page element mismatch");
                seen++;
            }
        }

        assertEq(seen, all.length, "paging lost or duplicated entries");
    }

    // Максимальный limit не переполняет расчёт окна.
    // На реализации через offset + limit этот вызов давал Panic(0x11),
    // хотя NatSpec обещает клампинг границ вместо реверта.
    function test_PagedHugeLimitDoesNotPanic() public {
        address[] memory made = _createSafes(3);

        address[] memory all = f.getSafesForOwnerPaged(a, 0, type(uint256).max);
        assertEq(all.length, 3, "huge limit at offset 0");
        for (uint256 i; i < 3; i++) {
            assertEq(all[i], made[i], "element mismatch at offset 0");
        }

        // Ненулевой offset - именно та комбинация, что переполнялась.
        address[] memory tail = f.getSafesForOwnerPaged(a, 2, type(uint256).max);
        assertEq(tail.length, 1, "huge limit at non-zero offset");
        assertEq(tail[0], made[2], "element mismatch at tail");

        // offset за концом вместе с максимальным limit тоже отдаёт пустой список.
        assertEq(f.getSafesForOwnerPaged(a, 3, type(uint256).max).length, 0, "offset past end");
    }

    // Пагинация работает для каждого из трёх совладельцев одинаково.
    function test_PagedConsistentForAllOwners() public {
        _createSafes(4);

        address[3] memory people = [a, b, c];
        for (uint256 i; i < 3; i++) {
            address who = people[i];

            assertEq(f.safesCountForOwner(who), 4);

            address[] memory all = f.getSafesForOwner(who);
            address[] memory page = f.getSafesForOwnerPaged(who, 0, 4);

            for (uint256 j; j < 4; j++) {
                assertEq(page[j], all[j]);
            }
        }
    }
}
