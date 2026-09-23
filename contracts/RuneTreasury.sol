// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RuneRegistry} from "./RuneRegistry.sol";

/// @title RuneTreasury — kas faksi yang dibatasi kontrak, bukan oleh niat baik
///
/// Ini jawaban untuk pertanyaan yang membunuh setiap demo "agen pegang wallet sendiri":
/// *apa yang terjadi saat agen itu salah, atau tersesat, atau dibajak?*
///
/// Versi awal proyek ini (0G) hanya memeriksa `msg.sender == agen` lalu melepas jumlah
/// berapa pun. Itu bukan otonomi, itu tombol tanpa pengaman. Di sini empat gerbang
/// ditegakkan oleh bytecode, dan semuanya bisa dibaca dari state tanpa harus mempercayai kami:
///
///  1. `perActionCap`  — satu aksi tidak boleh melewatinya.
///  2. `dailyCap`      — plafon per hari UTC; yang dilacak jumlah rupiahnya, bukan cuma
///     jumlah transaksinya, jadi seratus aksi kecil tidak lolos.
///  3. `minInterval`   — jeda antar belanja; mematahkan "habiskan kas dalam satu blok".
///  4. `allowedTarget` — daftar alamat yang boleh menerima dana. Default kosong: agen
///     tidak bisa mengirim ke alamat karangan sendiri.
///
/// Plus satu pembeda yang tidak ada di versi lama: **plafonnya ikut reputasi agen**
/// (`registry.tierOf`). Agen yang gagal terus mengecilkan plafonnya sendiri, dan itu
/// terjadi di chain — bukan karena kami mematikan prosesnya manual saat juri menonton.
///
/// Batas yang TIDAK dihapus kontrak ini:
///  - Ia membatasi *berapa* dan *ke mana*, bukan *apakah* sebuah aksi masuk akal. Aksi yang
///    lolos semua gerbang tapi tetap bodoh masih bisa terjadi; itu memang taruhannya otonomi.
///  - Plafon harian bergantung `block.timestamp`, yang bisa digeser penambang belasan detik.
///    Untuk jendela satu hari itu tidak relevan; jangan diklaim lebih kuat dari itu.
contract RuneTreasury is Ownable {
    /// @notice Plafon maksimum yang boleh dipasang seorang guardian per aksi.
    uint96 public constant HARD_PER_ACTION_CAP = 0.01 ether;
    /// @notice Plafon maksimum harian (sebelum diskalakan reputasi).
    uint96 public constant HARD_DAILY_CAP = 0.05 ether;
    /// @notice Batas jumlah tingkat reputasi yang mempengaruhi plafon, supaya agen senior
    ///     tidak memperoleh kas tak terbatas.
    uint256 public constant MAX_TIER_BONUS = 3;
    /// @notice Kenaikan plafon per tingkat reputasi, dalam persen.
    uint256 public constant TIER_BONUS_PERCENT = 20;

    struct Faction {
        address guardian;
        /// @notice Saldo faksi ini sendiri. Bukan `address(this).balance`: tanpa pencatatan per
        ///     faksi, satu faksi bisa membelanjakan dana yang disetor faksi lain — kontrak akan
        ///     terlihat aman padahal hanya kas bersama yang dijaga rata-rata.
        uint96 balance;
        uint96 perActionCap;
        uint96 dailyCap;
        uint32 minInterval;
        uint64 dayIndex;
        uint96 spentToday;
        uint64 lastSpendAt;
        uint96 totalSpent;
        uint32 spends;
        bool frozen;
        bool exists;
    }

    RuneRegistry public immutable REGISTRY;

    mapping(uint96 => Faction) private _factions;
    uint96[] private _factionIds;
    /// @dev faction => target => boleh menerima dana.
    mapping(uint96 => mapping(address => bool)) private _allowedTargets;

    event FactionCreated(uint96 indexed factionId, address indexed guardian);
    event PolicySet(uint96 indexed factionId, uint96 perActionCap, uint96 dailyCap, uint32 minInterval);
    event TargetSet(uint96 indexed factionId, address indexed target, bool allowed);
    event Deposited(uint96 indexed factionId, address indexed from, uint96 amount);
    /// @notice Satu-satunya jalan uang KELUAR tanpa melewati permainan. `remaining` ikut
    ///     dilaporkan supaya auditor tidak perlu panggilan tambahan untuk mengecek buku kas.
    event Withdrawn(uint96 indexed factionId, address indexed guardian, uint96 amount, uint96 remaining);
    event Spent(uint96 indexed factionId, address indexed agent, address indexed target, uint96 amount, bytes32 proofHash);
    event FactionFrozen(uint96 indexed factionId, bool frozen);

    error UnknownFaction();
    error AlreadyExists();
    error NotGuardian();
    error GuardianMismatch();
    error OnlyWorld();
    error ZeroAddress();
    error CapTooHigh();
    error FactionFrozenError();
    error TargetNotAllowed();
    error AbovePerActionCap();
    error AboveDailyCap();
    error TooSoon();
    error EmptyProof();
    error NotEnoughFunds();
    error TransferFailed();

    constructor(address registry_) Ownable(msg.sender) {
        if (registry_ == address(0)) revert ZeroAddress();
        REGISTRY = RuneRegistry(payable(registry_));
    }

    // ------------------------------------------------------------------ setup

    /// @notice Siapa pun boleh membuka kas faksi; pembukanya menjadi guardian.
    function createFaction(uint96 factionId) external {
        if (_factions[factionId].exists) revert AlreadyExists();
        _factions[factionId] = Faction({
            guardian: msg.sender,
            balance: 0,
            // Mulai dari nol: izin belanja harus diminta, tidak diwarisi.
            perActionCap: 0,
            dailyCap: 0,
            minInterval: 60,
            dayIndex: 0,
            spentToday: 0,
            lastSpendAt: 0,
            totalSpent: 0,
            spends: 0,
            frozen: false,
            exists: true
        });
        _factionIds.push(factionId);
        emit FactionCreated(factionId, msg.sender);
    }

    /// @notice Guardian memasang batas. Tidak bisa melewati plafon keras platform.
    /// @dev Tidak ada jalur "unlimited": 0 berarti tidak boleh belanja, dan tidak ada
    ///      nilai yang berarti tanpa batas.
    function setPolicy(uint96 factionId, uint96 perActionCap, uint96 dailyCap, uint32 minInterval) external {
        Faction storage f = _requireFaction(factionId);
        if (f.guardian != msg.sender) revert NotGuardian();
        if (perActionCap > HARD_PER_ACTION_CAP || dailyCap > HARD_DAILY_CAP) revert CapTooHigh();
        f.perActionCap = perActionCap;
        f.dailyCap = dailyCap;
        f.minInterval = minInterval;
        emit PolicySet(factionId, perActionCap, dailyCap, minInterval);
    }

    /// @notice Guardian menentukan alamat mana yang boleh menerima dana faksi.
    function setTarget(uint96 factionId, address target, bool allowed) external {
        Faction storage f = _requireFaction(factionId);
        if (f.guardian != msg.sender) revert NotGuardian();
        if (allowed && target == address(0)) revert ZeroAddress();
        _allowedTargets[factionId][target] = allowed;
        emit TargetSet(factionId, target, allowed);
    }

    /// @notice Guardian bisa membekukan faksinya seketika. Ini rem pemilik, bukan rem venue.
    function setFrozen(uint96 factionId, bool frozen) external {
        Faction storage f = _requireFaction(factionId);
        if (f.guardian != msg.sender) revert NotGuardian();
        f.frozen = frozen;
        emit FactionFrozen(factionId, frozen);
    }

    /// @notice Setoran ke kas faksi. Siapa pun boleh menambah; yang membatasi adalah pengeluaran.
    /// @dev Faksi mencatat `balance`-nya sendiri, dan kontrak ini sengaja tidak punya
    ///      `receive()`: transfer polos tanpa menyebut faksi akan jadi dana tak bertuan, jadi
    ///      lebih baik ditolak di depan.
    function deposit(uint96 factionId) external payable {
        Faction storage f = _requireFaction(factionId);
        f.balance += uint96(msg.value);
        emit Deposited(factionId, msg.sender, uint96(msg.value));
    }

    /// @dev Satu panggilan yang memindahkan DAN mencatat: `world` menyerahkan jarahan ke kas
    ///      faksi. Kalau pencatatannya terpisah dari pemindahannya, selalu ada jendela di mana
    ///      uangnya sudah pindah tapi bukunya belum.
    function credit(uint96 factionId) external payable {
        if (msg.sender != REGISTRY.world()) revert OnlyWorld();
        Faction storage f = _requireFaction(factionId);
        f.balance += uint96(msg.value);
        emit Deposited(factionId, msg.sender, uint96(msg.value));
    }

    /// @notice Guardian menarik kembali dana faksinya. **Ini satu-satunya pintu keluar.**
    ///
    /// Tanpa fungsi ini alur keuangan pemain berbentuk pintu satu arah: setor bisa, berhenti
    /// tidak bisa. Itu bukan sekadar ketidaknyamanan — klaim proyek ini adalah "agen boleh
    /// pegang uang karena pemiliknya masih pegang kendali", dan kendali tanpa jalan keluar itu
    /// namanya ditahan.
    ///
    /// Tiga keputusan yang disengaja di sini:
    ///  - **Hanya guardian.** Agen tidak punya hak tarik: uang yang boleh dibelanjakan agen
    ///    adalah uang yang boleh dia habiskan, bukan yang boleh dia amankan untuk dirinya.
    ///  - **Tetap bisa saat faksi beku.** `frozen` adalah rem untuk *aksi*, bukan untuk *pemilik*.
    ///    Rem yang mengunci dana pemiliknya sendiri berubah jadi alat sandera — dan yang memasang
    ///    rem itu justru pemiliknya, jadi pembekuan tidak boleh bisa mengurung uangnya sendiri.
    ///  - **Tidak dihitung sebagai belanja.** Penarikan bukan aksi permainan: ia tidak menyentuh
    ///    `spentToday`, `spends`, atau `totalSpent`. Yang dibatasi di sini adalah seberapa boros
    ///    seorang AGEN, bukan seberapa cepat pemiliknya boleh berhenti main.
    function withdraw(uint96 factionId, uint96 amount) external {
        Faction storage f = _requireFaction(factionId);
        if (f.guardian != msg.sender) revert NotGuardian();
        if (amount > f.balance) revert NotEnoughFunds();

        // Urutan checks-effects-interaction: saldo sudah dikurangi SEBELUM uang keluar, jadi
        // kalau penerimanya kontrak yang mencoba masuk lagi, dia melihat kas yang sudah susut.
        // (Tidak perlu "mengembalikan" saldo saat transfer gagal: revert membatalkan semua state
        // di transaksi itu — menulis saldo kembali di sini hanya akan jadi kode yang tampak
        // melindungi padahal tidak melakukan apa pun.)
        f.balance -= amount;
        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(factionId, msg.sender, amount, f.balance);
    }

    // ------------------------------------------------------------------ gerbang belanja

    /// @notice Membelanjakan dana faksi untuk satu aksi agen. Hanya `world` yang bisa memanggil.
    /// @dev `agent` menentukan faksi dan tingkat reputasinya. `proofHash` wajib ada: belanja
    ///      tanpa referensi ke catatan aksi adalah kas tanpa kwitansi.
    function spend(address agent, address target, uint96 amount, bytes32 proofHash) external {
        if (msg.sender != REGISTRY.world()) revert OnlyWorld();
        if (proofHash == bytes32(0)) revert EmptyProof();
        if (amount == 0) return;

        RuneRegistry.Agent memory a = REGISTRY.getAgent(agent);
        uint96 factionId = a.factionId;
        Faction storage f = _requireFaction(factionId);

        // Tanpa gerbang ini, seseorang cukup mendaftarkan agennya dengan factionId milik
        // orang lain (registerAgent menerima id berapa pun) dan kas korban menjadi
        // sasaran. Agen hanya boleh membelanjakan kas yang guardian-nya sendiri:
        // guardian faksi dan guardian agen harus address yang sama.
        if (f.guardian != a.guardian) revert GuardianMismatch();

        if (f.frozen) revert FactionFrozenError();
        if (!_allowedTargets[factionId][target]) revert TargetNotAllowed();

        uint256 tier = REGISTRY.tierOf(agent);

        if (amount > _scaledCap(f.perActionCap, tier)) revert AbovePerActionCap();

        uint64 day = uint64(block.timestamp / 1 days);
        uint96 spent = f.dayIndex == day ? f.spentToday : 0;
        if (spent + amount > _scaledCap(f.dailyCap, tier)) revert AboveDailyCap();

        if (f.spends > 0 && block.timestamp < uint256(f.lastSpendAt) + f.minInterval) revert TooSoon();
        // Yang ditanya adalah saldo FAKSI ini, bukan saldo kontrak. Membedanya di sini yang
        // membuat satu faksi tidak bisa diam-diam membelanjakan setoran faksi lain.
        if (f.balance < amount) revert NotEnoughFunds();

        f.dayIndex = day;
        f.spentToday = spent + amount;
        f.lastSpendAt = uint64(block.timestamp);
        f.totalSpent += amount;
        f.spends += 1;
        f.balance -= amount;

        (bool ok, ) = target.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit Spent(factionId, agent, target, amount, proofHash);
    }

    // ------------------------------------------------------------------ baca

    /// @notice Plafon efektif seorang agen, setelah skala reputasi. Dipakai runtime agen
    ///         untuk memutuskan aksi mana yang masih mungkin sebelum mencoba mengirim.
    function effectiveCaps(address agent) external view returns (uint96 perAction, uint96 daily) {
        RuneRegistry.Agent memory a = REGISTRY.getAgent(agent);
        Faction storage f = _requireFaction(a.factionId);
        uint256 tier = REGISTRY.tierOf(agent);
        return (_scaledCap(f.perActionCap, tier), _scaledCap(f.dailyCap, tier));
    }

    function getFaction(uint96 factionId) external view returns (Faction memory) {
        return _requireFaction(factionId);
    }

    /// @notice Ada tidaknya faksi. `getFaction` revert untuk yang tak dikenal, jadi pembacaan
    ///     yang hanya ingin bertanya "sudah ada?" butuh fungsi ini, bukan try/catch.
    function factionExists(uint96 factionId) external view returns (bool) {
        return _factions[factionId].exists;
    }

    function isTargetAllowed(uint96 factionId, address target) external view returns (bool) {
        return _allowedTargets[factionId][target];
    }

    function factionIds() external view returns (uint96[] memory) {
        return _factionIds;
    }

    // Tidak ada `receive()`: dana yang masuk tanpa menyebut faksi akan jadi dana tak bertuan
    // yang tidak bisa dibelanjakan siapa pun. Lebih baik transfer polos ditolak di depan.

    // ------------------------------------------------------------------ internal

    function _requireFaction(uint96 factionId) internal view returns (Faction storage f) {
        f = _factions[factionId];
        if (!f.exists) revert UnknownFaction();
    }

    /// @dev Plafon dasar + bonus reputasi, dibatasi MAX_TIER_BONUS supaya tidak meledak.
    function _scaledCap(uint96 base, uint256 tier) internal pure returns (uint96) {
        if (base == 0) return 0;
        uint256 cappedTier = tier > MAX_TIER_BONUS ? MAX_TIER_BONUS : tier;
        return uint96(uint256(base) * (100 + cappedTier * TIER_BONUS_PERCENT) / 100);
    }
}
