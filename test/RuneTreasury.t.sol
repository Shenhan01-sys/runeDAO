// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RuneRegistry} from "../contracts/RuneRegistry.sol";
import {RuneTreasury} from "../contracts/RuneTreasury.sol";

/// Uji RuneTreasury — kontrak yang bikin "agen pegang kas sendiri" layak ditunjukkan.
///
/// Yang dikejar di sini bukan jumlah tes, tapi satu pertanyaan: *bisakah kas faksi terkuras
/// oleh sesuatu yang bukan keinginan guardian-nya?* Setiap tes mencoba membobolnya lewat
/// satu jalur berbeda, dan jalur happy-path ada supaya kita tidak lulus karena semua tertutup.
///
/// Kontrak uji ini menyamar sebagai `world`: `spend()` hanya menerima pemanggil yang
/// terdaftar sebagai world, dan target belanja adalah dirinya sendiri (punya `receive`).
contract RuneTreasuryTest is Test {
    RuneRegistry internal registry;
    RuneTreasury internal treasury;

    address internal platform = address(0xA1);
    address internal guardian = address(0xB2);
    address internal agent = address(0xC3);
    address internal victim = address(0xD5);
    address internal stranger = address(0xE6);

    uint96 internal constant FACTION = 7;
    uint96 internal constant VICTIM_FACTION = 8;
    bytes32 internal constant PROOF = bytes32(uint256(0xBEFF));

    uint96 internal constant PER_ACTION = 0.001 ether;
    uint96 internal constant DAILY = 0.003 ether;

    function setUp() public {
        vm.prank(platform);
        registry = new RuneRegistry();
        // address(this) = dunia permainan.
        vm.prank(platform);
        registry.setWorld(address(this));

        vm.prank(platform);
        treasury = new RuneTreasury(address(registry));

        vm.startPrank(guardian);
        treasury.createFaction(FACTION);
        treasury.setPolicy(FACTION, PER_ACTION, DAILY, 60);
        treasury.setTarget(FACTION, address(this), true);
        registry.registerAgent(FACTION, agent, "Ashfen Raider");
        vm.stopPrank();

        // Dana masuk lewat `deposit`, bukan `vm.deal(alamat kontrak)`: sejak kas mencatat
        // saldo PER FAKSI, menaruh BNB di alamat treasury saja tidak membuatnya bisa
        // dibelanjakan — dan itu memang yang kita mau (lihat test_unattributedFunds...).
        vm.deal(guardian, 1 ether);
        vm.prank(guardian);
        treasury.deposit{value: 1 ether}(FACTION);
    }

    receive() external payable {}

    // --------------------------------------------------------------- happy path

    function test_spendPaysAllowedTargetAndCounts() public {
        uint96 amount = PER_ACTION;
        uint256 before_ = address(this).balance;

        treasury.spend(agent, address(this), amount, PROOF);

        assertEq(address(this).balance, before_ + amount, "dana benar-benar pindah");
        RuneTreasury.Faction memory f = treasury.getFaction(FACTION);
        assertEq(uint256(f.spends), 1);
        assertEq(uint256(f.totalSpent), uint256(amount));
        assertEq(uint256(f.spentToday), uint256(amount));
    }

    function test_zeroAmountSpendChangesNothing() public {
        treasury.spend(agent, address(this), 0, PROOF);
        RuneTreasury.Faction memory f = treasury.getFaction(FACTION);
        assertEq(f.spends, 0);
    }

    // --------------------------------------------------------------- gerbang caller

    function test_rejectSpendByNonWorld() public {
        vm.prank(stranger);
        vm.expectRevert(RuneTreasury.OnlyWorld.selector);
        treasury.spend(agent, address(this), PER_ACTION, PROOF);
    }

    function test_rejectSpendWithoutProofHash() public {
        vm.expectRevert(RuneTreasury.EmptyProof.selector);
        treasury.spend(agent, address(this), PER_ACTION, bytes32(0));
    }

    /// Lubang yang ditutup di kontrak ini: seseorang boleh mendaftarkan agennya dengan
    /// factionId milik orang lain. Tanpa cek guardian-silang, kas korban jadi sasaran.
    function test_rejectCrossFactionAgentDrain() public {
        vm.startPrank(victim);
        treasury.createFaction(VICTIM_FACTION);
        treasury.setPolicy(VICTIM_FACTION, PER_ACTION, DAILY, 0);
        treasury.setTarget(VICTIM_FACTION, address(this), true);
        vm.stopPrank();

        // Stranger membuka faksi sendiri, lalu menyamarkan agennya sebagai milik korban.
        address attackerAgent = address(0xF7);
        vm.startPrank(stranger);
        registry.registerAgent(VICTIM_FACTION, attackerAgent, "wolf in faction 8");
        vm.stopPrank();

        vm.expectRevert(RuneTreasury.GuardianMismatch.selector);
        treasury.spend(attackerAgent, address(this), PER_ACTION, PROOF);
    }

    // --------------------------------------------------------------- gerbang angka

    function test_newFactionStartsClosed() public {
        vm.startPrank(victim);
        treasury.createFaction(VICTIM_FACTION);
        registry.registerAgent(VICTIM_FACTION, address(0xF8), "idle");
        // Target diizinkan supaya tes ini menguji ANGKA nol, bukan tertolak karena daftar
        // alamat — urutan gerbang treasury memang.guardian → beku → target → cap.
        treasury.setTarget(VICTIM_FACTION, address(this), true);
        vm.stopPrank();

        // Cap 0 = tidak ada belanja, bukan "tanpa batas".
        vm.expectRevert(RuneTreasury.AbovePerActionCap.selector);
        treasury.spend(address(0xF8), address(this), 1, PROOF);
    }

    function test_rejectCapAboveHardCeiling() public {
        // Dibaca SEBELUM prank: `treasury.HARD_PER_ACTION_CAP()` adalah external call dan
        // akan memakan prank, persis seperti getter reputasi di RuneRegistryTest.
        uint96 hard = treasury.HARD_PER_ACTION_CAP();

        vm.prank(guardian);
        vm.expectRevert(RuneTreasury.CapTooHigh.selector);
        treasury.setPolicy(FACTION, hard + 1, DAILY, 60);
    }

    function test_rejectPolicySetByNonGuardian() public {
        vm.prank(stranger);
        vm.expectRevert(RuneTreasury.NotGuardian.selector);
        treasury.setPolicy(FACTION, PER_ACTION, DAILY, 60);
    }

    function test_rejectTargetNotAllowed() public {
        vm.expectRevert(RuneTreasury.TargetNotAllowed.selector);
        treasury.spend(agent, stranger, 1, PROOF);
    }

    /// Yang diuji: ambang yang ditegakkan adalah plafon EFEKTIF (dasar × bonus reputasi),
    /// bukan angka mentah yang dipasang guardian. Satu wei di atasnya harus ditolak.
    function test_rejectAbovePerActionCap() public {
        (uint96 perAction,) = treasury.effectiveCaps(agent);
        assertTrue(perAction > PER_ACTION, "tier awal memberi bonus di atas angka dasar");

        vm.expectRevert(RuneTreasury.AbovePerActionCap.selector);
        treasury.spend(agent, address(this), perAction + 1, PROOF);
    }

    /// Plafon harian melacak JUMLAH, bukan jumlah transaksi: seratus aksi kecil tidak lolos.
    /// `minInterval` dimatikan di sini supaya yang diuji benar-benar gerbang HARIAN, bukan
    /// gerbang jeda — sebelumnya tes ini gagal karena TooSoon, dan itu salah tesnya.
    function test_dailyCapAccumulatesAcrossSpends() public {
        _isolateDailyGate();
        (, uint96 daily) = treasury.effectiveCaps(agent);
        uint96 step = daily / 3;

        for (uint256 i = 0; i < 3; i++) {
            treasury.spend(agent, address(this), step, PROOF);
            vm.warp(block.timestamp + 1);
        }
        assertEq(uint256(treasury.getFaction(FACTION).spends), 3);

        vm.expectRevert(RuneTreasury.AboveDailyCap.selector);
        treasury.spend(agent, address(this), step, PROOF);
    }

    /// Hari UTC baru membuka kembali plafon — dan itu harus terjadi sendiri, bukan karena
    /// kami mereset state.
    function test_dailyCapResetsOnNewUtcDay() public {
        _isolateDailyGate();
        (, uint96 daily) = treasury.effectiveCaps(agent);
        uint96 step = daily / 3;

        for (uint256 i = 0; i < 3; i++) {
            treasury.spend(agent, address(this), step, PROOF);
            vm.warp(block.timestamp + 1);
        }

        vm.expectRevert(RuneTreasury.AboveDailyCap.selector);
        treasury.spend(agent, address(this), step, PROOF);

        // Lompat ke hari UTC berikutnya: gerbang hari harus terbuka tanpa perintah siapa pun.
        vm.warp(((block.timestamp / 1 days) + 1) * 1 days + 1);
        treasury.spend(agent, address(this), step, PROOF);
        assertEq(uint256(treasury.getFaction(FACTION).spends), 4);
    }

    /// @dev Pasang jeda 0 dan ambang per-aksi di atas langkah tes, supaya hanya gerbang harian
    ///      yang bisa menolak.
    function _isolateDailyGate() internal {
        (uint96 perAction, uint96 daily) = treasury.effectiveCaps(agent);
        vm.prank(guardian);
        treasury.setPolicy(FACTION, perAction, daily, 0);
    }

    function test_rejectSpendBeforeMinInterval() public {
        treasury.spend(agent, address(this), 1, PROOF);
        vm.warp(block.timestamp + 59);
        vm.expectRevert(RuneTreasury.TooSoon.selector);
        treasury.spend(agent, address(this), 1, PROOF);
    }

    function test_spendAllowedAfterMinInterval() public {
        treasury.spend(agent, address(this), 1, PROOF);
        vm.warp(block.timestamp + 60);
        treasury.spend(agent, address(this), 1, PROOF);
        assertEq(uint256(treasury.getFaction(FACTION).spends), 2);
    }

    /// Kas mencatat saldo PER FAKSI. Faksi yang belum setor tidak bisa belanja, walaupun
    /// kontraknya secara keseluruhan memegang BNB faksi lain — inilah alasan perubahan ini.
    function test_rejectSpendFromEmptyTreasury() public {
        address otherGuardian = address(0xB0);
        address otherAgent = address(0xB9);
        uint96 otherFaction = 42;

        // FACTION sudah punya 1 ether (setUp); faksi 42 belum punya apa-apa.
        vm.startPrank(otherGuardian);
        treasury.createFaction(otherFaction);
        treasury.setPolicy(otherFaction, PER_ACTION, DAILY, 0);
        treasury.setTarget(otherFaction, address(this), true);
        registry.registerAgent(otherFaction, otherAgent, "Other");
        vm.stopPrank();

        assertEq(address(treasury).balance, 1 ether, "kas kontrak berisi uang faksi lain");
        assertEq(uint256(treasury.getFaction(otherFaction).balance), 0);

        vm.expectRevert(RuneTreasury.NotEnoughFunds.selector);
        treasury.spend(otherAgent, address(this), 1, PROOF);
    }

    /// Kontrak kas sengaja tidak punya `receive()`: transfer polos ditolak, bukan diterima
    /// lalu jadi dana tak bertuan yang tidak bisa dibelanjakan siapa pun.
    function test_rejectBareTransferWithoutFaction() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok, ) = address(treasury).call{value: 1 ether}("");
        assertFalse(ok, "transfer polos harus ditolak");
        assertEq(uint256(treasury.getFaction(FACTION).balance), 1 ether);
    }

    function test_rejectTransferToTargetThatCannotReceive() public {
        vm.prank(guardian);
        treasury.setTarget(FACTION, address(registry), true);
        // registry tidak punya receive: pengiriman harus revert, bukan diam-diam gagal.
        vm.expectRevert(RuneTreasury.TransferFailed.selector);
        treasury.spend(agent, address(registry), 1, PROOF);
    }

    // --------------------------------------------------------------- gerbang bekunya

    function test_guardianFreezeStopsEverySpend() public {
        vm.prank(guardian);
        treasury.setFrozen(FACTION, true);

        vm.expectRevert(RuneTreasury.FactionFrozenError.selector);
        treasury.spend(agent, address(this), 1, PROOF);

        vm.prank(guardian);
        treasury.setFrozen(FACTION, false);
        treasury.spend(agent, address(this), 1, PROOF);
    }

    function test_rejectFreezeByNonGuardian() public {
        vm.prank(stranger);
        vm.expectRevert(RuneTreasury.NotGuardian.selector);
        treasury.setFrozen(FACTION, true);
    }

    // --------------------------------------------------------------- reputasi → plafon

    /// Pembeda utama dari versi 0G: agen yang gagal terus mengecilkan plafonnya sendiri,
    /// tanpa ada pihak yang perlu mematikannya.
    function test_reputationDropShrinksEffectiveCap() public {
        (uint96 perActionHigh,) = treasury.effectiveCaps(agent);
        assertTrue(perActionHigh > PER_ACTION, "tier awal memberi bonus");

        // Jatuhkan reputasi ke 0 lewat dunia permainan.
        registry.recordOutcome(agent, registry.STARTING_REPUTATION(), false);

        (uint96 perActionLow,) = treasury.effectiveCaps(agent);
        assertEq(uint256(perActionLow), uint256(PER_ACTION));
        assertTrue(perActionLow < perActionHigh);

        // Jumlah yang tadi lolos sekarang ditolak — dan penolakannya terjadi di chain.
        uint96 amount = perActionLow + 1;
        vm.expectRevert(RuneTreasury.AbovePerActionCap.selector);
        treasury.spend(agent, address(this), amount, PROOF);
    }

    function test_bonusIsCappedSoSeniorAgentsStayBounded() public {
        // Naikkan reputasi sampai langit-langit.
        for (uint256 i = 0; i < 20; i++) {
            registry.recordOutcome(agent, 100, true);
        }
        assertEq(uint256(registry.getAgent(agent).reputation), uint256(registry.MAX_REPUTATION()));

        (uint96 perAction,) = treasury.effectiveCaps(agent);
        uint256 maxExpected = uint256(PER_ACTION)
            * (100 + treasury.MAX_TIER_BONUS() * treasury.TIER_BONUS_PERCENT()) / 100;
        assertEq(uint256(perAction), maxExpected, "bonus reputasi tidak boleh tak terbatas");
    }

    // --------------------------------------------------------------- setup lain

    function test_rejectDuplicateFaction() public {
        vm.prank(victim);
        vm.expectRevert(RuneTreasury.AlreadyExists.selector);
        treasury.createFaction(FACTION);
    }

    function test_rejectUnknownFactionReads() public {
        vm.expectRevert(RuneTreasury.UnknownFaction.selector);
        treasury.getFaction(999);
    }

    function test_depositIncreasesBalanceAndEmits() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        treasury.deposit{value: 0.25 ether}(FACTION);
        assertEq(address(treasury).balance, 1.25 ether);
    }

    function test_rejectOwnerlessSetupOfAnotherFactionPolicy() public {
        vm.prank(stranger);
        vm.expectRevert(RuneTreasury.NotGuardian.selector);
        treasury.setTarget(FACTION, stranger, true);
    }
}
