// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PixelTurf} from "../src/PixelTurf.sol";

contract PixelTurfTest is Test {
    PixelTurf internal turf;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);

    uint16 internal constant W = 64;
    uint16 internal constant H = 64;
    uint64 internal constant CD = 30;

    event TilePlaced(address indexed player, uint16 x, uint16 y, uint8 color);

    function setUp() public {
        // The test contract itself is the deployer.
        turf = new PixelTurf();
    }

    /*//////////////////////////////////////////////////////////////
                                HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_PlaceTile_And_ReadBack() public {
        vm.prank(alice);
        turf.placeTile(3, 4, 7);

        assertEq(turf.getTile(3, 4), 7, "getTile should reflect placement");

        uint256 index = uint256(4) * W + 3;

        bytes memory row = turf.getRow(4);
        assertEq(row.length, W, "row length");
        assertEq(uint8(row[3]), 7, "getRow should reflect placement");

        bytes memory canvas = turf.getCanvas();
        assertEq(canvas.length, 4096, "canvas length");
        assertEq(uint8(canvas[index]), 7, "getCanvas should reflect placement");
    }

    function test_UnpaintedTilesReadAsBlankZero() public view {
        assertEq(turf.getTile(0, 0), 0);
        assertEq(turf.getTile(63, 63), 0);

        bytes memory canvas = turf.getCanvas();
        for (uint256 i = 0; i < canvas.length; ++i) {
            assertEq(uint8(canvas[i]), 0, "fresh canvas must be all zero");
        }
    }

    function test_GetRegion_ReflectsPlacements() public {
        vm.prank(alice);
        turf.placeTile(1, 1, 4);
        vm.startPrank(bob);
        turf.placeTile(2, 2, 9);
        vm.stopPrank();

        bytes memory region = turf.getRegion(1, 1, 2, 2);
        assertEq(region.length, 4);
        assertEq(uint8(region[0]), 4); // (1,1)
        assertEq(uint8(region[1]), 0); // (2,1)
        assertEq(uint8(region[2]), 0); // (1,2)
        assertEq(uint8(region[3]), 9); // (2,2)
    }

    /*//////////////////////////////////////////////////////////////
                                BOUNDS
    //////////////////////////////////////////////////////////////*/

    function test_Revert_OutOfBounds_X() public {
        vm.expectRevert(abi.encodeWithSelector(PixelTurf.OutOfBounds.selector, uint16(64), uint16(0)));
        vm.prank(alice);
        turf.placeTile(64, 0, 1);
    }

    function test_Revert_OutOfBounds_Y() public {
        vm.expectRevert(abi.encodeWithSelector(PixelTurf.OutOfBounds.selector, uint16(0), uint16(64)));
        vm.prank(alice);
        turf.placeTile(0, 64, 1);
    }

    function test_Revert_OutOfBounds_At_And_Past_Edge() public {
        vm.expectRevert(abi.encodeWithSelector(PixelTurf.OutOfBounds.selector, uint16(64), uint16(64)));
        vm.prank(alice);
        turf.placeTile(64, 64, 1);

        vm.expectRevert(abi.encodeWithSelector(PixelTurf.OutOfBounds.selector, uint16(100), uint16(100)));
        vm.prank(alice);
        turf.placeTile(100, 100, 1);
    }

    function test_Revert_InvalidColor() public {
        vm.expectRevert(abi.encodeWithSelector(PixelTurf.InvalidColor.selector, uint8(16)));
        vm.prank(alice);
        turf.placeTile(0, 0, 16);
    }

    /*//////////////////////////////////////////////////////////////
                               COOLDOWN
    //////////////////////////////////////////////////////////////*/

    function test_Cooldown_BlocksThenAllowsAfterWarp() public {
        vm.prank(alice);
        turf.placeTile(0, 0, 1);

        uint64 nextAt = turf.nextAllowedAt(alice);
        assertEq(nextAt, uint64(block.timestamp) + CD, "nextAllowedAt");

        vm.expectRevert(abi.encodeWithSelector(PixelTurf.CooldownActive.selector, nextAt));
        vm.prank(alice);
        turf.placeTile(1, 0, 2);

        vm.warp(nextAt);
        vm.prank(alice);
        turf.placeTile(1, 0, 2);
        assertEq(turf.getTile(1, 0), 2);
    }

    function test_Cooldown_IsPerAddress() public {
        vm.prank(alice);
        turf.placeTile(0, 0, 1);

        // Bob is not cooling down and may place immediately.
        vm.prank(bob);
        turf.placeTile(1, 0, 2);
        assertEq(turf.getTile(1, 0), 2);

        // Alice still is.
        vm.expectRevert();
        vm.prank(alice);
        turf.placeTile(2, 0, 3);
    }

    function test_Cooldown_KeyedByMsgSender_CannotPlaceForAnother() public {
        // There is no `player` argument: the key is always msg.sender.
        vm.prank(bob);
        turf.placeTile(7, 7, 5);

        assertEq(turf.lastPlacedAt(bob), uint64(block.timestamp), "bob is the one on cooldown");
        assertEq(turf.lastPlacedAt(alice), 0, "alice untouched");

        // Pranking as alice then placing affects alice, proving msg.sender rules.
        vm.prank(alice);
        turf.placeTile(8, 8, 6);
        assertEq(turf.lastPlacedAt(alice), uint64(block.timestamp));
        assertEq(turf.getTile(8, 8), 6);
    }

    /*//////////////////////////////////////////////////////////////
                         OVERWRITE / NO ERASE
    //////////////////////////////////////////////////////////////*/

    function test_LaterPlayerCanOverwrite_Painting() public {
        vm.prank(alice);
        turf.placeTile(10, 10, 3);

        vm.warp(block.timestamp + CD + 1);
        vm.prank(bob);
        turf.placeTile(10, 10, 9); // painting over is allowed by design

        assertEq(turf.getTile(10, 10), 9);
    }

    function test_ABI_ExposesOnlyExpectedFunctions_NoEraseOrAdmin() public {
        bytes memory code = vm.getDeployedCode("PixelTurf.sol:PixelTurf");
        bytes4[] memory found = _extractSelectors(code);

        bytes4[] memory expected = new bytes4[](11);
        expected[0] = bytes4(keccak256("placeTile(uint16,uint16,uint8)"));
        expected[1] = bytes4(keccak256("getTile(uint16,uint16)"));
        expected[2] = bytes4(keccak256("getRow(uint16)"));
        expected[3] = bytes4(keccak256("getRegion(uint16,uint16,uint16,uint16)"));
        expected[4] = bytes4(keccak256("getCanvas()"));
        expected[5] = bytes4(keccak256("nextAllowedAt(address)"));
        expected[6] = bytes4(keccak256("lastPlacedAt(address)"));
        expected[7] = bytes4(keccak256("WIDTH()"));
        expected[8] = bytes4(keccak256("HEIGHT()"));
        expected[9] = bytes4(keccak256("COOLDOWN()"));
        expected[10] = bytes4(keccak256("PALETTE_SIZE()"));

        assertEq(found.length, expected.length, "unexpected number of external functions");
        for (uint256 i = 0; i < expected.length; ++i) {
            assertTrue(_contains(found, expected[i]), "missing expected selector");
        }
        for (uint256 i = 0; i < found.length; ++i) {
            assertTrue(_contains(expected, found[i]), "unexpected extra function in ABI");
        }

        // Explicitly assert that no erase/admin/upgrade style selector exists.
        string[11] memory forbidden = [
            "owner()",
            "setOwner(address)",
            "transferOwnership(address)",
            "renounceOwnership()",
            "reset()",
            "clear()",
            "clearAll()",
            "batchPaint(uint16[],uint16[],uint8[])",
            "upgradeTo(address)",
            "withdraw()",
            "sweep(address)"
        ];
        for (uint256 i = 0; i < forbidden.length; ++i) {
            bytes4 sel = bytes4(keccak256(bytes(forbidden[i])));
            assertFalse(_contains(found, sel), "forbidden selector present in ABI");
        }
    }

    function test_OnlyPlaceTileWritesTileState() public {
        // placeTile is the only non-view function: every other selector in the
        // ABI is a pure/view getter and cannot mutate state.
        bytes4 place = bytes4(keccak256("placeTile(uint16,uint16,uint8)"));
        bytes4[] memory found = _extractSelectors(vm.getDeployedCode("PixelTurf.sol:PixelTurf"));
        assertTrue(_contains(found, place));
        // Sanity: constants are what the spec demands.
        assertEq(turf.WIDTH(), 64);
        assertEq(turf.HEIGHT(), 64);
        assertEq(turf.COOLDOWN(), 30);
        assertEq(turf.PALETTE_SIZE(), 16);
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    function test_Event_TilePlaced_CarriesPlayerAndCoords() public {
        vm.expectEmit(true, false, false, true, address(turf));
        emit TilePlaced(alice, 5, 6, 8);

        vm.prank(alice);
        turf.placeTile(5, 6, 8);
    }

    /*//////////////////////////////////////////////////////////////
                                  GAS
    //////////////////////////////////////////////////////////////*/

    function test_Gas_PlaceTileIsFlat_FirstVsThousandth() public {
        uint256 total = 1000;
        uint256 gasFirst;
        uint256 gasLast;

        for (uint256 i = 0; i < total; ++i) {
            // A distinct player and a distinct tile every iteration so the
            // cooldown slot and the tile slot are both fresh (cold) each time.
            address player = address(uint160(0x100000 + i));
            uint16 x = uint16(i % W);
            uint16 y = uint16(i / W);
            uint8 color = uint8((i % 15) + 1);

            vm.prank(player);
            uint256 before = gasleft();
            turf.placeTile(x, y, color);
            uint256 used = before - gasleft();

            if (i == 0) gasFirst = used;
            if (i == total - 1) gasLast = used;
        }

        emit log_named_uint("gas first placement", gasFirst);
        emit log_named_uint("gas 1000th placement", gasLast);

        // No growth with canvas fill: gas should not increase by more than 5%.
        assertLe(gasLast, gasFirst + (gasFirst * 5) / 100);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPLOYER HAS NO POWERS
    //////////////////////////////////////////////////////////////*/

    function test_DeployerHasNoSpecialPowers() public {
        assertEq(turf.lastPlacedAt(address(this)), 0);

        // As the deployer, the same cooldown applies.
        turf.placeTile(20, 20, 1);
        assertEq(turf.getTile(20, 20), 1);

        vm.expectRevert(abi.encodeWithSelector(PixelTurf.CooldownActive.selector, uint64(block.timestamp) + CD));
        turf.placeTile(21, 20, 2);

        vm.warp(block.timestamp + CD);
        turf.placeTile(21, 20, 2);
        assertEq(turf.getTile(21, 20), 2);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Extract every 4-byte function selector from the runtime dispatcher
    ///      (pattern: PUSH4 <selector> EQ) and de-duplicate.
    function _extractSelectors(bytes memory code) internal pure returns (bytes4[] memory found) {
        bytes4[] memory tmp = new bytes4[](64);
        uint256 n;
        for (uint256 i = 0; i + 5 < code.length; ++i) {
            if (code[i] == 0x63 && code[i + 5] == 0x14) {
                uint32 v = (uint32(uint8(code[i + 1])) << 24) | (uint32(uint8(code[i + 2])) << 16)
                    | (uint32(uint8(code[i + 3])) << 8) | uint32(uint8(code[i + 4]));
                bytes4 sel = bytes4(v);
                bool dup;
                for (uint256 j = 0; j < n; ++j) {
                    if (tmp[j] == sel) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) tmp[n++] = sel;
            }
        }
        found = new bytes4[](n);
        for (uint256 j = 0; j < n; ++j) {
            found[j] = tmp[j];
        }
    }

    function _contains(bytes4[] memory arr, bytes4 sel) internal pure returns (bool) {
        for (uint256 i = 0; i < arr.length; ++i) {
            if (arr[i] == sel) return true;
        }
        return false;
    }
}
