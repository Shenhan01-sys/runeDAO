// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RuneRegistry} from "../contracts/RuneRegistry.sol";

/// Uji RuneRegistry.
///
/// Empat klaim yang dikejar, karena keempatnya akan diucapkan ke juri:
///  1. reputasi bisa TURUN, bukan cuma naik;
///  2. hanya dunia permainan yang boleh mengubahnya;
///  3. guardian (pemilik agen) bukan platform — dan platform tidak bisa menyamar jadi dia;
///  4. `delist` mencabut izin tanpa menghapus riwayat, dan itu beda dari `suspend`.
contract RuneRegistryTest is Test {
    RuneRegistry internal registry;

    address internal platform = address(0xA1);
    address internal guardian = address(0xB2);
    address internal agent = address(0xC3);
    address internal world = address(0xD4);

    bytes32 internal constant CAP_RAID = keccak256("RAID");

    function setUp() public {
        vm.prank(platform);
        registry = new RuneRegistry();

        // `world` harus ditetapkan sebelum ada yang bisa mengubah reputasi: tanpa ini
        // setiap recordOutcome revert OnlyWorld dan suite-nya hijau karena alasan salah.
        vm.prank(platform);
        registry.setWorld(world);

        vm.prank(guardian);
        registry.registerAgent(7, agent, "Ashfen Raider");
    }

    // --------------------------------------------------------------- pendaftaran

    function test_register_setsGuardianFactionAndStartingReputation() public view {
        RuneRegistry.Agent memory a = registry.getAgent(agent);
        assertEq(a.guardian, guardian);
        assertEq(uint256(a.factionId), 7);
        assertEq(uint256(a.reputation), uint256(registry.STARTING_REPUTATION()));
        assertEq(a.actions, 0);
        assertTrue(registry.isOperable(agent));
        assertEq(registry.agentCount(), 1);
    }

    function test_rejectDuplicateAgent() public {
        vm.prank(guardian);
        vm.expectRevert(RuneRegistry.AlreadyRegistered.selector);
        registry.registerAgent(7, agent, "again");
    }

    function test_rejectZeroAgent() public {
        vm.prank(guardian);
        vm.expectRevert(RuneRegistry.ZeroAddress.selector);
        registry.registerAgent(7, address(0), "ghost");
    }

    function test_rejectEmptyLabel() public {
        vm.prank(guardian);
        vm.expectRevert(RuneRegistry.EmptyLabel.selector);
        registry.registerAgent(7, address(0xEE), "");
    }

    function test_rejectUnknownAgentGet() public {
        vm.expectRevert(RuneRegistry.UnknownAgent.selector);
        registry.getAgent(address(0x99));
    }

    // --------------------------------------------------------------- kapabilitas

    function test_capabilityDefaultsClosed() public view {
        assertFalse(registry.hasCapability(agent, CAP_RAID));
    }

    function test_guardianGrantsCapability() public {
        vm.prank(guardian);
        registry.setCapability(agent, CAP_RAID, true);
        assertTrue(registry.hasCapability(agent, CAP_RAID));
    }

    /// Platform punya kuasa atas venue, tapi tidak atas kapabilitas agen orang lain.
    function test_rejectCapabilitySetByNonGuardian() public {
        vm.prank(platform);
        vm.expectRevert(RuneRegistry.NotGuardian.selector);
        registry.setCapability(agent, CAP_RAID, true);
    }

    function test_rejectCapabilityForUnknownAgent() public {
        vm.prank(guardian);
        vm.expectRevert(RuneRegistry.UnknownAgent.selector);
        registry.setCapability(address(0x99), CAP_RAID, true);
    }

    function test_guardianCanRevokeCapability() public {
        vm.startPrank(guardian);
        registry.setCapability(agent, CAP_RAID, true);
        registry.setCapability(agent, CAP_RAID, false);
        vm.stopPrank();
        assertFalse(registry.hasCapability(agent, CAP_RAID));
    }

    // --------------------------------------------------------------- reputasi dua arah

    function test_worldRaisesReputationOnSuccess() public {
        vm.prank(world);
        registry.recordOutcome(agent, 40, true);

        RuneRegistry.Agent memory a = registry.getAgent(agent);
        assertEq(uint256(a.reputation), uint256(registry.STARTING_REPUTATION()) + 40);
        assertEq(a.actions, 1);
        assertEq(a.failures, 0);
    }

    /// Klaim kepala: reputasi TURUH saat aksi gagal.
    function test_worldLowersReputationOnFailure() public {
        uint24 before_ = registry.getAgent(agent).reputation;

        vm.prank(world);
        registry.recordOutcome(agent, 40, false);

        RuneRegistry.Agent memory a = registry.getAgent(agent);
        assertEq(uint256(a.reputation), uint256(before_) - 40);
        assertEq(a.failures, 1);
        assertEq(a.actions, 1);
    }

    function test_reputationClampsAtCeiling() public {
        vm.startPrank(world);
        for (uint256 i = 0; i < 40; i++) {
            registry.recordOutcome(agent, 100, true);
        }
        vm.stopPrank();

        assertEq(uint256(registry.getAgent(agent).reputation), uint256(registry.MAX_REPUTATION()));
    }

    /// Serangkaian kegagalan tidak boleh membuat angka jadi negatif (underflow) atau mandek
    /// di bawah nol — lantai 0 berarti "dilukai", bukan "dihapus".
    function test_reputationClampsAtFloorAndCountsEveryFailure() public {
        vm.startPrank(world);
        for (uint256 i = 0; i < 30; i++) {
            registry.recordOutcome(agent, 100, false);
        }
        vm.stopPrank();

        RuneRegistry.Agent memory a = registry.getAgent(agent);
        assertEq(uint256(a.reputation), uint256(registry.MIN_REPUTATION()));
        assertEq(a.failures, 30);
        assertEq(a.actions, 30);
        assertTrue(a.exists, "agen jatuh masih terdaftar");
    }

    /// Konsekuensi yang dipakai RuneTreasury: plafon ikut mengecil saat reputasi jatuh.
    function test_tierFallsWithReputation() public {
        assertEq(registry.tierOf(agent), 5);

        // Diambil SEBELUM prank: `registry.STARTING_REPUTATION()` sendiri adalah external
        // call, dan vm.prank berlaku untuk external call BERIKUTNYA — kalau dipanggil di
        // dalam argumen, prank-nya termakan getter dan recordOutcome datang dari alamat
        // test, bukan dari world.
        uint24 starting = registry.STARTING_REPUTATION();

        vm.prank(world);
        registry.recordOutcome(agent, starting, false);

        assertEq(registry.tierOf(agent), 0);
    }

    function test_rejectRecordOutcomeFromPlatform() public {
        vm.prank(platform);
        vm.expectRevert(RuneRegistry.OnlyWorld.selector);
        registry.recordOutcome(agent, 40, true);
    }

    function test_rejectRecordOutcomeFromGuardian() public {
        vm.prank(guardian);
        vm.expectRevert(RuneRegistry.OnlyWorld.selector);
        registry.recordOutcome(agent, 40, true);
    }

    function test_setWorldOnlyByOwner() public {
        address other = address(0x77);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        registry.setWorld(other);

        vm.prank(platform);
        registry.setWorld(world);
        assertEq(registry.world(), world);
    }

    function test_setWorldRejectsZero() public {
        vm.prank(platform);
        vm.expectRevert(RuneRegistry.ZeroAddress.selector);
        registry.setWorld(address(0));
    }

    function test_recordOutcomeRejectsUnknownAgent() public {
        vm.prank(world);
        vm.expectRevert(RuneRegistry.UnknownAgent.selector);
        registry.recordOutcome(address(0x99), 10, true);
    }

    // --------------------------------------------------------------- dua rem

    function test_guardianSuspendsOwnAgent() public {
        vm.prank(guardian);
        registry.suspend(agent, true);
        assertFalse(registry.isOperable(agent));

        vm.prank(guardian);
        registry.suspend(agent, false);
        assertTrue(registry.isOperable(agent));
    }

    function test_rejectSuspendByPlatform() public {
        vm.prank(platform);
        vm.expectRevert(RuneRegistry.NotGuardian.selector);
        registry.suspend(agent, true);
    }

    function test_platformDelistsButKeepsHistory() public {
        vm.prank(world);
        registry.recordOutcome(agent, 10, true);
        uint24 repBefore = registry.getAgent(agent).reputation;

        vm.prank(platform);
        registry.delist(agent, true);

        RuneRegistry.Agent memory a = registry.getAgent(agent);
        assertFalse(registry.isOperable(agent));
        assertEq(a.actions, 1, "riwayat aksi tidak dihapus");
        assertEq(uint256(a.reputation), uint256(repBefore), "reputasi tidak disita");
    }

    function test_rejectDelistByGuardian() public {
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        registry.delist(agent, true);
    }

    /// Setelah di-delist, agen tetap tidak boleh beroperasi meski guardian membuka suspend-nya:
    /// rem venue tidak bisa dilepas oleh pemilik agen.
    function test_delistCannotBeUndoneByGuardian() public {
        vm.startPrank(platform);
        registry.delist(agent, true);
        vm.stopPrank();

        vm.prank(guardian);
        registry.suspend(agent, false);
        assertFalse(registry.isOperable(agent));
    }

    function test_rosterListsEveryAgent() public {
        vm.prank(guardian);
        registry.registerAgent(7, address(0xAB), "Second");
        address[] memory all = registry.roster();
        assertEq(all.length, 2);
        assertEq(all[0], agent);
        assertEq(all[1], address(0xAB));
    }
}
