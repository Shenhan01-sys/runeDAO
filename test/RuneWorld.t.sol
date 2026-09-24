// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {RuneRegistry} from "../contracts/RuneRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RuneTreasury} from "../contracts/RuneTreasury.sol";
import {RuneWorld} from "../contracts/RuneWorld.sol";

/// Uji RuneWorld.
///
/// Dua hal yang dikejar di sini:
///  1. gerbang commit/resolve benar-benar menutup jalan "coba lagi sampai dapat" dan jalan
///     "komitmen sesudah hash bloknya diketahui" (itu isi klaim anti-kecurangan);
///  2. setiap aksi memindahkan uang lewat gerbang kas, dan konsekuensinya konsisten dengan
///     angka yang diumumkan di event.
///
/// Dadu TIDAK dipaksa menghasilkan angka tertentu - itu justru tidak bisa dilakukan dari
/// sisi tes, dan kalau bisa, berarti dadunya bocor. Sebaliknya: tes menjalankan banyak aksi
/// lalu menagih invariant pada setiap hasil yang benar-benar terjadi.
contract RuneWorldTest is Test {
    RuneRegistry internal registry;
    RuneTreasury internal treasury;
    RuneWorld internal world;

    address internal platform = address(0xA1);
    address internal guardianA = address(0xB2);
    address internal agentA = address(0xC3);
    address internal guardianB = address(0xD2);
    address internal agentB = address(0xD3);

    uint96 internal constant FACTION_A = 1;
    uint96 internal constant FACTION_B = 2;
    uint96 internal constant REGION = 0;
    uint96 internal constant OTHER_REGION = 1;

    bytes32 internal constant RAID = keccak256("RAID");
    bytes32 internal constant ENTRENCH = keccak256("ENTRENCH");
    bytes32 internal constant TRANSCRIPT = bytes32(uint256(0x715));

    uint256 internal constant AHEAD = 3;
    uint96 internal constant BASE_BOUNTY = 0.0004 ether;

    struct Act {
        bytes32 kind;
        uint8 roll;
        uint8 threshold;
        bool success;
        uint96 cost;
        uint32 strength;
        uint96 owner;
        bytes32 transcriptHash;
    }

    function setUp() public {
        vm.prank(platform);
        registry = new RuneRegistry();
        vm.prank(platform);
        treasury = new RuneTreasury(address(registry));
        vm.prank(platform);
        world = new RuneWorld(address(registry), address(treasury));

        // Rantai otoritas: hanya world yang mengubah reputasi, hanya world yang belanja dari kas.
        vm.prank(platform);
        registry.setWorld(address(world));

        // seedRegion sekarang MEMBAWA ETH (hadiah awal), jadi penaburnya harus punya saldo.
        // Kebutuhannya 6 x hadiah + sedikit untuk biaya; angka di bawah sengaja lebih besar.
        vm.deal(platform, 1 ether);
        for (uint96 i = 0; i < world.REGION_COUNT(); i++) {
            vm.prank(platform);
            world.seedRegion{value: BASE_BOUNTY}(i, "Vhal'Mor", 20, BASE_BOUNTY);
        }

        _openFaction(guardianA, agentA, FACTION_A);
        _openFaction(guardianB, agentB, FACTION_B);
    }

    function _openFaction(address guardian_, address agent_, uint96 factionId) internal {
        // Guardian harus punya BNB dulu: `deposit{value:}` dari alamat kosong revert, dan
        // kalau itu terjadi di setUp semua tes di suite ini mati karena alasan yang salah.
        vm.deal(guardian_, 1 ether);
        vm.startPrank(guardian_);
        treasury.createFaction(factionId);
        // Plafon harian dipasang di langit-langit keras dan jeda kas 0: tes invarian
        // menjalankan puluhan aksi dan tidak boleh tersandung gerbang KAS sementara ia
        // menagih gerbang PERMAINAN. Jeda aksi itu sendiri ditegakkan world (regionCooldown).
        treasury.setPolicy(factionId, 0.001 ether, 0.05 ether, 0);
        treasury.setTarget(factionId, address(world), true);
        treasury.deposit{value: 0.5 ether}(factionId);
        registry.registerAgent(factionId, agent_, "agent");
        registry.setCapability(agent_, RAID, true);
        registry.setCapability(agent_, ENTRENCH, true);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- helper satu aksi

    /// Commit lalu resolve sebagai `agent_`, melewati cooldown wilayah lebih dulu.
    /// Mengembalikan isi event Action yang baru saja dipancarkan.
    function _raid(address agent_, uint96 regionId, bytes32 secret) internal returns (Act memory) {
        return _act(agent_, regionId, RAID, secret);
    }

    function _act(address agent_, uint96 regionId, bytes32 kind, bytes32 secret) internal returns (Act memory) {
        vm.warp(block.timestamp + world.regionCooldown() + 1);

        uint32 target = uint32(block.number + AHEAD);
        bytes32 hash = keccak256(abi.encodePacked(secret, target, agent_, world.nonceOf(agent_) + 1));

        vm.recordLogs();
        vm.prank(agent_);
        world.commit(hash, regionId, kind, target, TRANSCRIPT);

        vm.roll(block.number + AHEAD + 1);
        vm.prank(agent_);
        world.resolve(secret);

        return _lastAction();
    }

    function _lastAction() internal view returns (Act memory a) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Tanpa jaga ini, lupa `vm.recordLogs()` muncul sebagai panic underflow di index
        // dan bukan sebagai pesan yang menjelaskan apa yang kurang.
        require(logs.length > 0, "tidak ada log tercatat: panggil vm.recordLogs() lebih dulu");
        Vm.Log memory last = logs[logs.length - 1];
        (a.kind, a.roll, a.threshold, a.success, a.cost, a.strength, a.owner, a.transcriptHash) =
            abi.decode(last.data, (bytes32, uint8, uint8, bool, uint96, uint32, uint96, bytes32));
    }

    // ---------------------------------------------------------------- genesis

    /// Wilayah baru harus lahir dengan hadiah: tanpa itu EV menyerang = P*0 - biaya, selalu
    /// negatif, dan dunia beku sejak menit pertama - persis yang terjadi pada musim 1.
    function test_regionIsSeededWithItsBounty() public {
        RuneWorld.Region memory r = world.getRegion(5);
        assertEq(uint256(r.pool), uint256(BASE_BOUNTY), "hadiah awal harus tertabung di wilayah");
        assertGe(address(world).balance, uint256(BASE_BOUNTY) * uint256(world.REGION_COUNT()), "uangnya nyata ada di world");
    }

    function test_seedRejectsWrongBountyValue() public {
        // Semua wilayah sudah ditabur setUp; memakai salah satunya akan menguji
        // RegionAlreadySeeded, bukan BountyMismatch - dan tesnya tetap hijau-ish kalau
        // kita tidak membaca error mana yang benar-benar datang.
        RuneWorld fresh = new RuneWorld(address(registry), address(treasury));
        // `fresh` di-deploy dari dalam kontrak test, jadi owner-nya address(this) - mem-prank
        // platform justru menghasilkan OwnableUnauthorizedAccount dan BountyMismatch tidak
        // pernah teruji. Ini persis jenis "tes lulus karena alasan yang salah" yang sudah
        // tiga kali muncul di sesi ini.
        vm.deal(address(this), 1 ether);
        vm.expectRevert(RuneWorld.BountyMismatch.selector);
        fresh.seedRegion{value: 1 wei}(0, "salah bayar", 20, BASE_BOUNTY);
    }

    function test_seedIsOneShot() public {
        vm.prank(platform);
        vm.expectRevert(RuneWorld.RegionAlreadySeeded.selector);
        world.seedRegion{value: BASE_BOUNTY}(REGION, "lagi", 20, BASE_BOUNTY);
    }

    function test_rejectSeedOutsideWorld() public {
        // Dibaca sebelum expectRevert: `world.REGION_COUNT()` adalah external call dan akan
        // memakan ekspektasi, sehingga tesnya "lulus" karena alasan yang salah.
        uint96 outside = world.REGION_COUNT();
        vm.prank(platform);
        vm.expectRevert(RuneWorld.RegionOutOfIndex.selector);
        world.seedRegion{value: BASE_BOUNTY}(outside, "di luar", 20, BASE_BOUNTY);
    }

    function test_rejectSeedByNonOwner() public {
        address thief = address(0xEE);
        // Tanpa saldo, pemindahan ETH gagal SEBELUM kontrak ikut dievaluasi dan forge
        // melaporkannya sebagai "revert di depth yang salah" - bukan sebagai onlyOwner.
        vm.deal(thief, 1 ether);
        vm.prank(thief);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, thief));
        world.seedRegion{value: BASE_BOUNTY}(3, "curian", 20, BASE_BOUNTY);
    }

    // ---------------------------------------------------------------- gerbang commit

    function test_commitRejectsUnregisteredAgent() public {
        vm.prank(address(0xEE));
        vm.expectRevert(RuneWorld.NotOperable.selector);
        world.commit(bytes32("x"), REGION, RAID, uint32(block.number + 3), TRANSCRIPT);
    }

    function test_commitRejectsMissingCapability() public {
        vm.prank(guardianB);
        registry.setCapability(agentB, RAID, false);

        vm.prank(agentB);
        vm.expectRevert(RuneWorld.CapabilityMissing.selector);
        world.commit(bytes32("x"), REGION, RAID, uint32(block.number + 3), TRANSCRIPT);
    }

    /// Agen yang didelist venue kehilangan dayung, termasuk hak berkomitmen.
    function test_commitRejectsDelistedAgent() public {
        vm.prank(platform);
        registry.delist(agentA, true);

        vm.prank(agentA);
        vm.expectRevert(RuneWorld.NotOperable.selector);
        world.commit(bytes32("x"), REGION, RAID, uint32(block.number + 3), TRANSCRIPT);
    }

    function test_commitRejectsSuspendedAgent() public {
        vm.prank(guardianA);
        registry.suspend(agentA, true);

        vm.prank(agentA);
        vm.expectRevert(RuneWorld.NotOperable.selector);
        world.commit(bytes32("x"), REGION, RAID, uint32(block.number + 3), TRANSCRIPT);
    }

    function test_commitRejectsEmptyTranscript() public {
        vm.prank(agentA);
        vm.expectRevert(RuneWorld.EmptyTranscript.selector);
        world.commit(bytes32("x"), REGION, RAID, uint32(block.number + 3), bytes32(0));
    }

    /// Jantung klaim anti-kecurangan: komitmen pada blok yang sudah ada berarti pelakunya
    /// sudah bisa membaca hash blok itu, jadi dia sedang memilih hasil, bukan mengundi.
    function test_commitRejectsTargetBlockInThePast() public {
        vm.prank(agentA);
        vm.expectRevert(RuneWorld.TargetBlockNotFuture.selector);
        world.commit(bytes32("x"), REGION, RAID, uint32(block.number), TRANSCRIPT);
    }

    function test_commitRejectsTargetBlockNow() public {
        vm.prank(agentA);
        vm.expectRevert(RuneWorld.TargetBlockNotFuture.selector);
        world.commit(bytes32("x"), REGION, RAID, uint32(block.number), TRANSCRIPT);
    }

    function test_commitRejectsTooDistantTargetBlock() public {
        uint32 tooFar = uint32(block.number + world.MAX_TARGET_HORIZON() + 1);
        vm.prank(agentA);
        vm.expectRevert(RuneWorld.TargetBlockTooFar.selector);
        world.commit(bytes32("x"), REGION, RAID, tooFar, TRANSCRIPT);
    }

    function test_commitRejectsUnknownRegion() public {
        vm.prank(agentA);
        vm.expectRevert(RuneWorld.RegionUnknown.selector);
        world.commit(bytes32("x"), 99, RAID, uint32(block.number + 3), TRANSCRIPT);
    }

    /// Dua commit terbuka adalah "coba lagi sampai dapat". Ditutup.
    function test_commitRejectsSecondOpenCommit() public {
        vm.prank(agentA);
        world.commit(bytes32("x"), REGION, RAID, uint32(block.number + 3), TRANSCRIPT);

        vm.prank(agentA);
        vm.expectRevert(RuneWorld.CommitAlreadyOpen.selector);
        world.commit(bytes32("y"), REGION, RAID, uint32(block.number + 4), TRANSCRIPT);
    }

    function test_regionCooldownBlocksSecondActor() public {
        uint32 target = uint32(block.number + AHEAD);
        vm.prank(agentA);
        world.commit(bytes32("x"), REGION, RAID, target, TRANSCRIPT);

        vm.prank(agentB);
        vm.expectRevert(RuneWorld.RegionCooldownActive.selector);
        world.commit(bytes32("y"), REGION, RAID, uint32(block.number + AHEAD), TRANSCRIPT);
    }

    // ---------------------------------------------------------------- gerbang resolve

    function test_resolveWithoutCommitReverts() public {
        vm.prank(agentA);
        vm.expectRevert(RuneWorld.NoCommit.selector);
        world.resolve(bytes32("tidak ada commit"));
    }

    function test_resolveRejectsSecretNotMatchingCommit() public {
        uint32 target = uint32(block.number + AHEAD);
        vm.prank(agentA);
        world.commit(bytes32("hash palsu"), REGION, RAID, target, TRANSCRIPT);

        vm.roll(block.number + AHEAD + 1);
        vm.prank(agentA);
        vm.expectRevert(RuneWorld.CommitMismatch.selector);
        world.resolve(bytes32("secret asal"));
    }

    function test_resolveRejectsBeforeTargetBlock() public {
        bytes32 secret = bytes32("s");
        uint32 target = uint32(block.number + AHEAD);
        bytes32 hash = keccak256(abi.encodePacked(secret, target, agentA, world.nonceOf(agentA) + 1));

        vm.prank(agentA);
        world.commit(hash, REGION, RAID, target, TRANSCRIPT);

        vm.prank(agentA);
        vm.expectRevert(RuneWorld.TargetBlockNotFuture.selector);
        world.resolve(secret);
    }

    /// Secret yang sama, nonce berbeda -> hash berbeda, jadi komitmennya tidak bisa ditukar.
    function test_resolveRejectsCommitFromPreviousNonce() public {
        bytes32 secret = bytes32("berulang");
        _raid(agentA, REGION, secret);

        // Commit lama sudah dihapus; pakai ulang secret-nya harus gagal sebagai CommitMismatch,
        // bukan diam-diam menyelesaikan aksi kedua.
        uint32 target = uint32(block.number + AHEAD);
        bytes32 wrongNonceHash = keccak256(abi.encodePacked(secret, target, agentA, uint256(1)));
        vm.warp(block.timestamp + world.regionCooldown() + 1);
        vm.prank(agentA);
        world.commit(wrongNonceHash, OTHER_REGION, RAID, target, TRANSCRIPT);

        vm.roll(block.number + AHEAD + 1);
        vm.prank(agentA);
        vm.expectRevert(RuneWorld.CommitMismatch.selector);
        world.resolve(secret);
    }

    // ---------------------------------------------------------------- uang

    function test_raidPaysExactlyItsCostThroughTheGate() public {
        RuneTreasury.Faction memory before_ = treasury.getFaction(FACTION_A);
        uint256 worldBefore = address(world).balance;
        assertEq(uint256(before_.spends), 0);

        Act memory a = _raid(agentA, REGION, bytes32("bayar"));

        RuneTreasury.Faction memory after_ = treasury.getFaction(FACTION_A);
        assertEq(uint256(after_.spends), 1);
        assertEq(uint256(a.cost), uint256(world.RAID_COST()));
        assertEq(uint256(before_.balance) - uint256(after_.balance), uint256(world.RAID_COST()));
        // Selisih, bukan saldo absolut: world kini memegang hadiah awal 6 wilayah, jadi
        // angka absolut akan selalu salah dan godaan untuk "mengoreksi" tesnya adalah
        // cara cepat membuat tes yang tidak menguji apa pun.
        assertEq(
            address(world).balance - worldBefore, uint256(world.RAID_COST()), "selisih kas world = satu biaya raid"
        );
    }

    /// Peristiwanya harus menyebut hash transaksi aksi, dan transcript agen ikut tercatat -
    /// itu tautan antara "yang ada di chain" dan "yang ada di log kami".
    function test_actionEventCarriesTheTranscriptHash() public {
        Act memory a = _raid(agentA, REGION, bytes32("transkrip"));
        assertEq(uint256(a.transcriptHash), uint256(TRANSCRIPT));
        assertEq(uint256(a.kind), uint256(RAID));
    }

    // ---------------------------------------------------------------- invarian permainan

    /// Menagih aturan main pada SETIAP hasil yang benar-benar terjadi, bukan pada hasil
    /// yang kita pilih. 40 raid dari dua agen berbeda cukup untuk menabrak kedua cabang.
    /// @notice Angka kebijakan yang mengubah ekonomi dunia. Naik-turunnya harus jadi
    ///         keputusan yang ditulis orang, bukan efek samping suntingan.
    function test_policyConstantsAreTheAdvertisedOnes() public view {
        assertEq(world.LOOT_SHARE_PERCENT(), 60, "pemenang mengambil 60% hadiah");
        assertEq(uint256(world.MIN_STRENGTH()), 10, "lantai kekuatan");
        assertEq(uint256(world.MAX_STRENGTH()), 40, "langit-langit kekuatan");
        assertEq(uint256(world.RAID_COST()), 300000000000000, "0,0003 BNB per raid");
        assertEq(uint256(world.ENTRENCH_COST()), 100000000000000, "0,0001 BNB per entrench");
        assertEq(uint256(world.regionCooldown()), 300, "300 detik");
        assertEq(uint256(world.reputationGain()), 25, "naik 25");
        assertEq(uint256(world.reputationLoss()), 40, "turun 40");
    }

    function test_invariantsHoldForEveryObservedOutcome() public {
        bool sawSuccess = false;
        bool sawFailure = false;
        // Penjaga cakupan: aturan jarahan 60% + lantai kekuatan hanya ditagih di cabang
        // "sukses dengan hadiah > 0". Kalau cabang itu tidak pernah terjadi, tes ini akan
        // hijau tanpa menguji apa pun - jadi keberuntungannya harus dinyatakan, bukan
        // diandaikan.
        bool sawLootWithBounty = false;

        for (uint256 i = 0; i < 40; i++) {
            address agent_ = i % 2 == 0 ? agentA : agentB;
            uint96 faction = i % 2 == 0 ? FACTION_A : FACTION_B;
            bytes32 secret = bytes32(abi.encodePacked("raid-", i));

            RuneWorld.Region memory before_ = world.getRegion(REGION);
            uint96 treasuryBefore = treasury.getFaction(faction).balance;
            Act memory a = _raid(agent_, REGION, secret);
            uint96 treasuryAfter = treasury.getFaction(faction).balance;

            // Dadu selalu dalam jangkauan dan ambang selalu dalam jangkauan yang sama.
            assertTrue(a.roll >= 1 && a.roll <= 20, "roll keluar dari d20");
            assertTrue(a.threshold >= 4 && a.threshold <= 19, "ambang tidak bisa dicapai d20");
            assertEq(a.success, a.roll >= a.threshold, "hasil tidak cocok dengan ambangnya sendiri");

            if (a.success) {
                sawSuccess = true;
                // Kemenangan memindahkan wilayah DAN seluruh pool ke kas pemenang. Ditulis
                // sebagai persamaan, bukan ">0": persamaan tidak bisa puas kalau uangnya
                // hilang separuh.
                assertEq(uint256(a.owner), uint256(faction), "wilayah jatuh ke pihak yang salah");
                // Pemenang mengambil LOOT_SHARE_PERCENT; sisanya TETAP jadi hadiah wilayah,
                // supaya penaklukan berikutnya masih punya alasan (dunia membeku tanpa ini).
                if (before_.pool > 0) {
                    sawLootWithBounty = true;
                }
                // ANGKA DITETAPKAN, tidak dibaca dari kontrak: versi pertama tes ini memakai
                // world.LOOT_SHARE_PERCENT() di kedua sisi persamaan, jadi mengubah konstanta
                // jadi 100 tetap hijau - tes tautologis yang hanya membuktikan kode konsisten
                // dengan dirinya sendiri. Ketertangkapannya diverifikasi dengan mutasi.
                uint256 loot = (uint256(before_.pool) * 60) / 100;
                assertEq(
                    uint256(treasuryAfter),
                    uint256(treasuryBefore) - uint256(world.RAID_COST()) + loot,
                    "buku kas pemenang tidak cocok"
                );
                assertEq(
                    uint256(world.getRegion(REGION).pool),
                    uint256(before_.pool) - loot,
                    "40% hadiah harus tertinggal di wilayah"
                );
                assertEq(
                    uint256(a.strength),
                    uint256(before_.strength > 16 ? before_.strength - 6 : 10),
                    "kekuatan harus berhenti di lantai 10, bukan meluncur ke nol"
                );
            } else {
                sawFailure = true;
                assertEq(uint256(a.owner), uint256(before_.owner), "wilayah berpindah padahal kalah");
                assertEq(
                    uint256(world.getRegion(REGION).pool),
                    uint256(before_.pool) + uint256(world.RAID_COST()),
                    "biaya raid yang gagal harus tertahan jadi pool, bukan hilang"
                );
                assertEq(uint256(a.strength), uint256(before_.strength < 40 ? before_.strength + 1 : 40));
            }

            // Kekuatan tidak pernah keluar dari rentang yang membuat ambang masuk akal.
            assertTrue(a.strength <= world.MAX_STRENGTH(), "kekuatan melewati plafon");
        }

        assertTrue(sawSuccess && sawFailure, "40 raid tidak menghasilkan kedua cabang - distribusi dicurigai");
        assertTrue(sawLootWithBounty, "tidak pernah ada keberhasilan di wilayah berhadiah: aturan jarahan tidak teruji");
    }

    /// Roll harus bisa dihitung ulang dari data publik: itu isi "bisa diaudit tanpa kami".
    function test_rollIsReproducibleFromPublicData() public {
        bytes32 secret = bytes32("formula");
        vm.warp(block.timestamp + world.regionCooldown() + 1);

        uint32 target = uint32(block.number + AHEAD);
        bytes32 hash = keccak256(abi.encodePacked(secret, target, agentA, world.nonceOf(agentA) + 1));

        vm.recordLogs();
        vm.prank(agentA);
        world.commit(hash, REGION, RAID, target, TRANSCRIPT);
        vm.roll(block.number + AHEAD + 1);
        vm.prank(agentA);
        world.resolve(secret);

        Act memory a = _lastAction();
        uint8 expected = uint8((uint256(keccak256(abi.encodePacked(secret, blockhash(target)))) % 20) + 1);
        assertEq(uint256(a.roll), uint256(expected), "roll tidak cocok dengan rumus yang didokumentasikan");
    }

    /// Secret yang sama menghasilkan angka berbeda pada blok berbeda: sumber utamanya memang
    /// hash blok, bukan secret - kebalikan dari versi 0G yang bisa dicari offline.
    function test_sameSecretDifferentBlockGivesDifferentRoll() public {
        bytes32 secret = bytes32("tetap");
        uint8 first = _raid(agentA, REGION, secret).roll;
        uint8 second = 0;
        for (uint256 i = 0; i < 40; i++) {
            second = _raid(agentA, REGION, secret).roll;
            if (second != first) {
                break;
            }
        }
        assertTrue(first != second, "secret sama di blok berbeda selalu menghasilkan angka sama");
    }

    // ---------------------------------------------------------------- entrench

    function test_entrenchRejectsNonOwnerOfRegion() public {
        // Semua wilayah netral di awal (owner = 0), jadi mengukuhkan harus ditolak.
        bytes32 secret = bytes32("e");
        uint32 target = uint32(block.number + AHEAD);
        bytes32 hash = keccak256(abi.encodePacked(secret, target, agentA, world.nonceOf(agentA) + 1));

        vm.prank(agentA);
        world.commit(hash, REGION, ENTRENCH, target, TRANSCRIPT);

        vm.roll(block.number + AHEAD + 1);
        vm.prank(agentA);
        vm.expectRevert(RuneWorld.NotRegionOwner.selector);
        world.resolve(secret);
    }

    function test_entrenchAllowedForRegionOwnerAndRaisesStrength() public {
        // Rebut REGION lebih dulu (mungkin butuh beberapa percobaan: dadu sungguhan).
        uint96 owner = 0;
        for (uint256 i = 0; i < 40 && owner != FACTION_A; i++) {
            owner = _raid(agentA, REGION, bytes32(abi.encodePacked("take", i))).owner;
        }
        require(owner == FACTION_A, "tidak bisa merebut wilayah untuk tes ini");

        uint32 before_ = world.getRegion(REGION).strength;
        Act memory a = _act(agentA, REGION, ENTRENCH, bytes32("kokoh"));
        assertTrue(a.strength >= before_, "mengukuhkan tidak boleh menurunkan kekuatan");
    }
    // ---------------------------------------------------------------- abandon

    /// Jalan keluar dari commit yang tidak jadi dibuka. Tanpa ini, satu proses agen yang mati
    /// di antara dua transaksi mengunci agen itu selamanya (CommitAlreadyOpen terus-menerus).
    function test_abandonRejectsWhileRevealWindowStillOpen() public {
        bytes32 secret = bytes32("belum dibuka");
        uint32 target = _openCommitOnly(agentA, REGION, RAID, secret);

        // Baru beberapa blok lewat: masih sah untuk resolve, jadi belum boleh dibuang.
        vm.roll(block.number + 4);
        vm.prank(agentA);
        vm.expectRevert(RuneWorld.RevealWindowOpen.selector);
        world.abandon();
    }

    function test_abandonRejectsWithoutCommit() public {
        vm.prank(agentA);
        vm.expectRevert(RuneWorld.NoCommit.selector);
        world.abandon();
    }

    /// Agen yang kabur dari aksinya membayar dengan reputasi — dan karena plafon belanja
    /// mengikuti reputasi, harga itu nyata, bukan seremonial.
    function test_abandonCostsReputationAndFreesTheAgent() public {
        uint24 repBefore = registry.getAgent(agentA).reputation;
        (uint96 capBefore,) = treasury.effectiveCaps(agentA);

        bytes32 secret = bytes32("dibuang");
        uint32 target = _openCommitOnly(agentA, REGION, RAID, secret);

        // Lewati jendela reveal: blockhash(target) tidak bisa dibaca lagi, resolve mustahil.
        vm.roll(uint64(target) + 257);

        vm.prank(agentA);
        world.abandon();

        RuneRegistry.Agent memory a = registry.getAgent(agentA);
        assertEq(uint256(a.reputation), uint256(repBefore) - uint256(world.reputationLoss()));
        assertEq(a.failures, 1, "kabur dihitung sebagai kegagalan");
        assertEq(a.actions, 1, "aksi tercatat meski tidak diselesaikan");
        assertTrue(!world.getCommit(agentA).exists, "commit harus hilang");

        (uint96 capAfter,) = treasury.effectiveCaps(agentA);
        assertTrue(capAfter <= capBefore, "kabur tidak boleh memperbesar plafon");

        // Setelah dibuang, agen boleh berkomitmen lagi.
        _openCommitOnly(agentA, OTHER_REGION, RAID, bytes32("lagi"));
    }

    /// Uang tidak boleh berpindah saat agen kabur: biaya aksi dibayar di resolve, jadi
    /// abandonment tidak menyentuh kas — dan pool wilayah tidak bertambah.
    function test_abandonMovesNoMoney() public {
        RuneTreasury.Faction memory facBefore = treasury.getFaction(FACTION_A);
        uint256 poolBefore = uint256(world.getRegion(REGION).pool);
        uint256 worldBalBefore = address(world).balance;
        bytes32 secret = bytes32("uang tidak gerak");
        uint32 target = _openCommitOnly(agentA, REGION, RAID, secret);
        vm.roll(uint64(target) + 257);

        vm.prank(agentA);
        world.abandon();

        RuneTreasury.Faction memory facAfter = treasury.getFaction(FACTION_A);
        assertEq(uint256(facAfter.balance), uint256(facBefore.balance), "abandon tidak boleh menarik kas");
        assertEq(facAfter.spends, facBefore.spends);
        // Yang ditagih "tidak ada yang berpindah", bukan "pool nol": tiap wilayah memang lahir
        // membawa hadiah awal. Menulis assertEq(x, x) di sini akan hijau tanpa menguji apa pun.
        assertEq(uint256(world.getRegion(REGION).pool), poolBefore, "hadiah wilayah tidak berubah");
        assertEq(address(world).balance, worldBalBefore, "kas world tidak bergerak");
    }

    /// Commit yang dibuang tidak bisa dibuka lagi setelahnya.
    function test_resolveAfterAbandonReverts() public {
        bytes32 secret = bytes32("sudah dibuang");
        uint32 target = _openCommitOnly(agentA, REGION, RAID, secret);
        vm.roll(uint64(target) + 257);

        vm.startPrank(agentA);
        world.abandon();
        vm.expectRevert(RuneWorld.NoCommit.selector);
        world.resolve(secret);
        vm.stopPrank();
    }

    /// @dev Hanya berkomitmen (tidak resolve); mengembalikan targetBlock yang dipakai.
    function _openCommitOnly(address agent_, uint96 regionId, bytes32 kind, bytes32 secret) internal returns (uint32) {
        vm.warp(block.timestamp + world.regionCooldown() + 1);
        uint32 target = uint32(block.number + AHEAD);
        bytes32 hash = keccak256(abi.encodePacked(secret, target, agent_, world.nonceOf(agent_) + 1));
        vm.prank(agent_);
        world.commit(hash, regionId, kind, target, TRANSCRIPT);
        return target;
    }
}
