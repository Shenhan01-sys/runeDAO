// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RuneRegistry} from "./RuneRegistry.sol";
import {RuneTreasury} from "./RuneTreasury.sol";

/// @title RuneWorld — mesin permainan yang menentukan siapa benar
///
/// Kontrak ini satu-satunya yang boleh mengubah reputasi. Itu pilihan, bukan kebetulan:
/// kalau pemilik agen atau venue yang boleh menaikkan angkanya, "reputasi" cuma jadi opini
/// siapa yang memegang kunci.
///
/// ## Dadu: kenapa tidak menyalin commit-reveal versi 0G
///
/// Versi lamarnya menerima `secret` dari pihak yang sama yang berkomitmen, asal hash-nya
/// cocok — jadi hasilnya bisa dicari offline sebelum di-reveal. Di sini commit mengikat ke
/// **nomor blok yang belum ditambang**:
///
/// ```text
/// commit  : hash  = keccak256(secret, targetBlock, agent, nonce)     // targetBlock di masa depan
/// resolve : seed  = keccak256(secret, blockhash(targetBlock))
///           roll  = seed % 20 + 1
/// ```
///
/// Saat agen berkomitmen, `blockhash(targetBlock)` belum ada, jadi dia tidak bisa menghitung
/// hasilnya lebih dulu dan memilih yang menguntungkan.
///
/// Batas yang TIDAK dihapus kontrak ini, dan tidak boleh diklaim menghapusnya:
///  - Validator yang menambang `targetBlock` masih bisa mempengaruhi hash bloknya sendiri
///    secara kecil. Cukup untuk permainan; tidak cukup untuk angka besar. Bukan "provably fair".
///  - Yang dibuktikan di sini adalah **aturan**, bukan **kebenaran keputusan agen**. Mutu
///    keputusannya tidak kami klaim — itu butuh verifiable inference, yang tidak tersedia
///    sebagai lapisan first-party di chain ini.
///  - Dunianya sengaja kecil: 6 wilayah, dua jenis aksi. Yang dijual mekanismenya.
contract RuneWorld is Ownable {
    RuneRegistry public immutable REGISTRY;
    RuneTreasury public immutable TREASURY;

    /// @notice Nama aksi dipakai sekaligus sebagai capability di RuneRegistry.
    bytes32 public constant KIND_RAID = keccak256("RAID");
    bytes32 public constant KIND_ENTRENCH = keccak256("ENTRENCH");

    uint96 public constant RAID_COST = 0.0003 ether;
    uint96 public constant ENTRENCH_COST = 0.0001 ether;

    /// @notice Jumlah wilayah dunia. Kecil dan selesai, bukan luas dan menggantung.
    uint96 public constant REGION_COUNT = 6;
    /// @notice Kekuatan wilayah dijaga di 0..MAX_STRENGTH supaya ambang raid tidak pernah
    ///         jadi mustahil atau jadi formalitas.
    uint32 public constant MAX_STRENGTH = 40;
    /// @notice Jarak maksimum `targetBlock` dari blok sekarang.
    uint32 public constant MAX_TARGET_HORIZON = 20;
    /// @notice `blockhash()` hanya membaca 256 blok ke belakang.
    uint256 internal constant BLOCKHASH_WINDOW = 256;

    struct Region {
        string name;
        uint96 owner; // factionId; 0 = belum dimiliki siapa pun
        uint32 strength;
        uint96 pool; // dana yang menumpuk dari raid yang gagal
        address lastDefender;
        uint64 lastActed;
        bool seeded;
    }

    struct Commit {
        bytes32 hash;
        bytes32 transcriptHash;
        uint32 targetBlock;
        uint96 regionId;
        bytes32 kind;
        uint64 madeAt;
        bool exists;
    }

    mapping(uint96 => Region) private _regions;
    mapping(address => Commit) private _commits;
    mapping(address => uint256) private _nonces;

    uint256 public actionCount;
    uint256 public raidsWon;
    uint256 public raidsFailed;

    uint24 public reputationGain = 25;
    uint24 public reputationLoss = 40;
    uint32 public regionCooldown = 300;

    event RegionSeeded(uint96 indexed regionId, string name, uint32 strength);
    event RollCommitted(
        address indexed agent,
        uint96 indexed regionId,
        bytes32 indexed kind,
        bytes32 commitHash,
        uint32 targetBlock,
        uint256 nonce
    );
    event Action(
        bytes32 indexed actionId,
        address indexed agent,
        uint96 indexed regionId,
        bytes32 kind,
        uint8 roll,
        uint8 threshold,
        bool success,
        uint96 cost,
        uint32 strength,
        uint96 owner,
        bytes32 transcriptHash
    );
    event LootPaid(uint96 indexed regionId, uint96 indexed toFaction, address indexed agent, uint96 amount);
    event PolicySet(uint24 reputationGain, uint24 reputationLoss, uint32 regionCooldown);
    event CommitAbandoned(address indexed agent, uint96 indexed regionId, bytes32 indexed kind, uint32 targetBlock, uint24 reputationLost);

    error NotOperable();
    error CapabilityMissing();
    error RegionUnknown();
    error RegionAlreadySeeded();
    error RegionOutOfIndex();
    error RegionCooldownActive();
    error CommitAlreadyOpen();
    error NoCommit();
    error EmptySecret();
    error EmptyTranscript();
    error TargetBlockNotFuture();
    error TargetBlockTooFar();
    error TargetBlockUnavailable();
    error CommitMismatch();
    error UnknownKind();
    error NotRegionOwner();
    error ZeroAddress();
    error RevealWindowOpen();
    error NoPendingAbandon();

    constructor(address registry_, address treasury_) Ownable(msg.sender) {
        if (registry_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        REGISTRY = RuneRegistry(payable(registry_));
        TREASURY = RuneTreasury(address(treasury_));
    }

    // ------------------------------------------------------------------ genesis

    function seedRegion(uint96 regionId, string calldata name, uint32 strength) external onlyOwner {
        if (regionId >= REGION_COUNT) revert RegionOutOfIndex();
        Region storage r = _regions[regionId];
        if (r.seeded) revert RegionAlreadySeeded();
        r.name = name;
        r.strength = strength > MAX_STRENGTH ? MAX_STRENGTH : strength;
        r.seeded = true;
        emit RegionSeeded(regionId, name, r.strength);
    }

    // ------------------------------------------------------------------ langkah 1

    /// @notice Agen mengumumkan niat tanpa membocorkan hasil.
    /// @param transcriptHash hash catatan keputusan di luar chain. Wajib ada: aksi tanpa
    ///        referensi ke alasannya bukan otonomi, itu cuma tombol.
    function commit(bytes32 hash, uint96 regionId, bytes32 kind, uint32 targetBlock, bytes32 transcriptHash) external {
        if (!REGISTRY.isOperable(msg.sender)) revert NotOperable();
        if (!REGISTRY.hasCapability(msg.sender, kind)) revert CapabilityMissing();
        if (transcriptHash == bytes32(0)) revert EmptyTranscript();
        if (targetBlock <= block.number) revert TargetBlockNotFuture();
        if (targetBlock > block.number + MAX_TARGET_HORIZON) revert TargetBlockTooFar();

        // Satu commit terbuka per agen. Menimpa commit lama tanpa menyelesaikan aksinya adalah
        // jalan termudah untuk "coba lagi sampai dapat". Cek ini sengaja di depan wilayah:
        // ini soal agen itu sendiri, dan menjawabnya dengan "wilayah sedang cooldown"
        // menyesatkan siapa pun yang membaca revert-nya.
        if (_commits[msg.sender].exists) revert CommitAlreadyOpen();

        Region storage r = _region(regionId);
        // `lastActed == 0` berarti wilayah ini belum pernah disentuh sama sekali — bukan
        // "baru saja acted". Tanpa pembeda itu, tiap wilayah terkunci selama cooldown penuh
        // sejak genesis, dan di jaringan dengan timestamp modern itu tak pernah kelihatan.
        if (r.lastActed != 0 && block.timestamp < uint256(r.lastActed) + regionCooldown) {
            revert RegionCooldownActive();
        }

        // Cooldown dihitung dari COMMIT, bukan dari penyelesaian aksi. Kalau tidak, dua agen
        // bisa sama-sama berkomitmen pada wilayah yang sama dan yang kedua menyelesaikan
        // aksinya di atas state yang sudah berubah — balapan yang tidak pernah kami mau.
        // Tidak ada state yang ditulis sebelum semua gerbang di atas lolos.
        r.lastActed = uint64(block.timestamp);

        uint256 nonce = ++_nonces[msg.sender];
        _commits[msg.sender] = Commit({
            hash: hash,
            transcriptHash: transcriptHash,
            targetBlock: targetBlock,
            regionId: regionId,
            kind: kind,
            madeAt: uint64(block.timestamp),
            exists: true
        });
        emit RollCommitted(msg.sender, regionId, kind, hash, targetBlock, nonce);
    }

    // ------------------------------------------------------------------ langkah 2

    /// @notice Membuka secret, menggulung dadu, menjalankan akibatnya.
    /// @dev Sengaja **tidak mengembalikan apa pun**. Yang bisa diaudit adalah event `Action`
    ///      dan pasangan (commit, secret) yang bisa dicocokkan ulang dari chain — nilai return
    ///      hanya menggoda pemanggil untuk mempercayai angka yang tidak perlu dipercayai.
    function resolve(bytes32 secret) external {
        Commit memory c = _commits[msg.sender];
        if (!c.exists) revert NoCommit();
        if (secret == bytes32(0)) revert EmptySecret();
        if (block.number <= c.targetBlock) revert TargetBlockNotFuture();
        if (block.number > uint256(c.targetBlock) + BLOCKHASH_WINDOW) revert TargetBlockUnavailable();

        bytes32 blockAtTarget = blockhash(c.targetBlock);
        if (blockAtTarget == bytes32(0)) revert TargetBlockUnavailable();

        uint256 nonce = _nonces[msg.sender];
        if (keccak256(abi.encodePacked(secret, c.targetBlock, msg.sender, nonce)) != c.hash) revert CommitMismatch();

        delete _commits[msg.sender];

        // Satu-satunya sumber angka dadu: hash blok yang belum ada saat agen berkomitmen.
        // forge-lint: disable-next-line(unsafe-typecast)  // `% 20 + 1` = 1..20, muat di uint8
        uint8 roll = uint8((uint256(keccak256(abi.encodePacked(secret, blockAtTarget))) % 20) + 1);
        bytes32 actionId = keccak256(abi.encodePacked(msg.sender, c.regionId, c.kind, nonce));
        uint96 cost = _costOf(c.kind);

        // Bayar lewat gerbang treasury SEBELUM bertindak. Kalau urutannya dibalik, agen bisa
        // mengubah state dunia lalu gagal bayar — dan aksi yang tidak membayar tidak boleh
        // meninggalkan efek.
        TREASURY.spend(msg.sender, address(this), cost, actionId);

        Region storage r = _regions[c.regionId];
        uint96 factionId = REGISTRY.getAgent(msg.sender).factionId;
        r.lastActed = uint64(block.timestamp);

        bool success;
        uint8 threshold;
        if (c.kind == KIND_RAID) {
            (success, threshold) = _raid(r, c.regionId, roll, cost, factionId, msg.sender);
        } else {
            success = _entrench(r, roll, factionId, msg.sender);
        }

        emit Action(
            actionId, msg.sender, c.regionId, c.kind, roll, threshold, success, cost, r.strength, r.owner, c.transcriptHash
        );
        actionCount += 1;
    }

    /// @dev Raid. Ambang 11 (=50% untuk d20) digeser selisih kekuatan; dijepit 4..19 supaya
    ///      wilayah terkuat pun tetap bisa direbut dan yang terlemah tidak gratis.
    function _raid(Region storage r, uint96 regionId, uint8 roll, uint96 cost, uint96 factionId, address agent)
        internal
        returns (bool success, uint8 threshold)
    {
        threshold = _thresholdOf(r.strength);
        success = roll >= threshold;

        if (success) {
            raidsWon += 1;
            uint96 loot = r.pool;
            if (loot > 0) {
                r.pool = 0;
                TREASURY.credit{value: loot}(factionId);
                emit LootPaid(regionId, factionId, agent, loot);
            }
            r.owner = factionId;
            r.lastDefender = address(0);
            r.strength = r.strength > 6 ? r.strength - 6 : 0;
            REGISTRY.recordOutcome(agent, reputationGain, true);
        } else {
            raidsFailed += 1;
            // Gagal bukan berarti uangnya hilang: biaya tertahan jadi hadiah bagi siapa pun
            // yang merebut wilayah ini nanti. Rugi bagi agennya, jadi milik dunia.
            r.pool += cost;
            r.strength = r.strength < MAX_STRENGTH ? r.strength + 1 : MAX_STRENGTH;
            REGISTRY.recordOutcome(agent, reputationLoss, false);
            address defender = r.lastDefender;
            if (defender != address(0) && defender != agent) {
                // Pembela yang tinggal di sini naik angkanya karena wilayahnya bertahan.
                REGISTRY.recordOutcome(defender, reputationGain, true);
            }
        }
    }

    /// @dev Mengukuhkan: naiknya kekuatan dibatasi roll, dan butuh pemilik wilayah.
    ///      Bukan kemenangan — yang berhasil cuma dibayar sedikit, yang gagal tidak dihukum.
    function _entrench(Region storage r, uint8 roll, uint96 factionId, address agent) internal returns (bool) {
        if (r.owner != factionId) revert NotRegionOwner();
        uint32 gain = uint32(roll / 4);
        r.strength = r.strength + gain > MAX_STRENGTH ? MAX_STRENGTH : r.strength + gain;
        r.lastDefender = agent;
        if (gain > 0) {
            REGISTRY.recordOutcome(agent, reputationGain / 5, true);
            return true;
        }
        return false;
    }

    // ------------------------------------------------------------------ jalan keluar

    /// @notice Membuang commit yang tidak jadi dibuka, SETELAH jendela reveal lewat.
    ///
    /// Kenapa ini harus ada: commit-reveal tanpa jalan keluar berarti satu proses agen yang
    /// mati di antara dua transaksi mengunci agen itu selamanya — `commit()` berikutnya akan
    /// selalu `CommitAlreadyOpen`. Itu bukan ketatnya aturan, itu denial-layanan oleh kecelakaan.
    ///
    /// Kenapa berbayar: kalau membuang commit itu gratis, agen bisa menggulung dadu, melihat
    /// hasilnya, lalu membuangnya saat jelek dan mencoba lagi. Jadi abandonment SELALU
    /// dihitung sebagai kegagalan reputasi, lewat jalur yang sama dengan raid gagal — dan
    /// karena plafon belanja mengikuti reputasi, agen yang sering kabur membatasi dirinya
    /// sendiri. Terornya tetap mungkin; harganya yang dibuat nyata.
    ///
    /// Jendela reveal = `targetBlock + 256`: sesudah itu `blockhash(targetBlock)` tidak bisa
    /// dibaca lagi dan resolve memang tidak akan pernah bisa berhasil.
    function abandon() external {
        Commit memory c = _commits[msg.sender];
        if (!c.exists) revert NoCommit();
        if (block.number <= uint256(c.targetBlock) + BLOCKHASH_WINDOW) revert RevealWindowOpen();

        delete _commits[msg.sender];

        uint24 lost = reputationLoss;
        REGISTRY.recordOutcome(msg.sender, lost, false);
        emit CommitAbandoned(msg.sender, c.regionId, c.kind, c.targetBlock, lost);
    }

    // ------------------------------------------------------------------ kebijakan

    /// @notice Angka yang menentukan seberapa keras dunia menghukum agen tidak boleh berubah
    ///         diam-diam: ada event-nya dan bisa dibaca dari chain.
    function setPolicy(uint24 reputationGain_, uint24 reputationLoss_, uint32 regionCooldown_) external onlyOwner {
        reputationGain = reputationGain_;
        reputationLoss = reputationLoss_;
        regionCooldown = regionCooldown_;
        emit PolicySet(reputationGain_, reputationLoss_, regionCooldown_);
    }

    // ------------------------------------------------------------------ baca

    function getRegion(uint96 regionId) external view returns (Region memory) {
        return _region(regionId);
    }

    function getCommit(address agent) external view returns (Commit memory) {
        return _commits[agent];
    }

    function nonceOf(address agent) external view returns (uint256) {
        return _nonces[agent];
    }

    /// @notice Ambang raid yang akan berlaku untuk sebuah wilayah, dibaca tanpa simulasi.
    ///         Dipakai runtime agen untuk memutuskan apakah sebuah aksi masuk akal.
    function raidThreshold(uint96 regionId) external view returns (uint8) {
        return _thresholdOf(_regions[regionId].strength);
    }

    receive() external payable {}

    function _thresholdOf(uint32 strength) internal pure returns (uint8) {
        int256 need = 11 + (int256(uint256(strength)) - 20) / 2;
        if (need < 4) need = 4;
        if (need > 19) need = 19;
        // forge-lint: disable-next-line(unsafe-typecast)  //need di-clip ke 4..19 tepat di atas
        return uint8(uint256(need));
    }

    function _region(uint96 regionId) internal view returns (Region storage r) {
        r = _regions[regionId];
        if (!r.seeded) revert RegionUnknown();
    }

    function _costOf(bytes32 kind) internal pure returns (uint96) {
        if (kind == KIND_RAID) return RAID_COST;
        if (kind == KIND_ENTRENCH) return ENTRENCH_COST;
        revert UnknownKind();
    }
}
