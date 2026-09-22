// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title RuneRegistry — daftar agen, kapabilitas, dan reputasi yang bisa TURUN
///
/// Kontrak ini menjawab satu pertanyaan yang bikin "agen otonom" biasanya cuma slogan:
/// *siapa yang boleh menyuruh agen ini, dan apa yang terjadi kalau dia salah?*
///
/// Tiga hal yang sengaja dirancang beda dari pola "daftar agen biasa":
///
///  1. **Guardian, bukan platform, yang punya agen.** Setiap agen didaftarkan oleh
///     `guardian`-nya sendiri (pemilik faksi). Platform tidak pernah memegang kunci agen
///     dan karena itu tidak bisa menandatangani atas namanya. Ini bukan detail tata kota:
///     begitu platform bisa bicara atas nama agen, "agen pihak ketiga" jadi hiasan.
///
///  2. **Reputasi bergerak dua arah dan hanya bisa digerakkan oleh dunia permainan.**
///     `recordOutcome()` dikunci untuk satu caller (`world`). Neither a guardian nor the
///     platform can top up a favorite agent's score. Konsekuensinya ditulis oleh mesin
///     permainan, bukan oleh kami.
///
///  3. **Dua rem yang berbeda, dan keduanya on-chain.** Guardian bisa `suspend()`
///     agen miliknya sendiri (pemilik menghentikan alatnya). Platform bisa `delist()`
///     (venue mencabut izin main). Keduanya menghasilkan keadaan yang sama-sama bisa
///     dibaca siapa pun — dan `delist` sengaja BUKAN penghapusan: aksi yang sudah
///     tercatat di chain tetap tercatat.
///
/// Batas yang TIDAK dihapus kontrak ini, dan tidak boleh diklaim menghapusnya:
///  - Ia tidak membuktikan agen itu "pintar", atau keputusannya baik. Ia hanya mengikat
///    siapa yang boleh bertindak, apa yang boleh, dan mencatat akibatnya.
///  - `reputation` adalah angka permainan yang dihitung kontrak ini dari hasil yang
///    disahkan `world`. Ia bukan skor kualitas model, dan bukan kredit sosial siapa pun.
contract RuneRegistry is Ownable {
    /// @notice Reputasi awal sebuah agen baru.
    uint24 public constant STARTING_REPUTATION = 500;
    /// @notice Langit-langit reputasi. Angka ini membatasi seberapa besar kredibilitas
    ///     seorang agen boleh menaiki batas belanjanya (lihat RuneTreasury).
    uint24 public constant MAX_REPUTATION = 1000;
    /// @notice Lantai reputasi. Agen yang jatuh ke sini masih boleh bertindak, tapi
    ///     hanya dengan batas terkecil — kami tidak mematikan agen, kami melihainya.
    uint24 public constant MIN_REPUTATION = 0;
    /// @notice Lebar satu tingkat reputasi untuk kebutuhan perhitungan batas belanja.
    uint24 public constant REPUTATION_STEP = 100;

    struct Agent {
        address guardian;
        uint96 factionId;
        string label;
        uint24 reputation;
        uint32 actions;
        uint32 failures;
        bool suspended;
        bool delisted;
        bool exists;
    }

    address public world;

    mapping(address => Agent) private _agents;
    address[] private _roster;
    /// @dev agent => capability => diizinkan. Default false: tidak ada yang boleh sampai
    ///      guardian-nya secara eksplisit mengizinkan.
    mapping(address => mapping(bytes32 => bool)) private _capabilities;

    event AgentRegistered(address indexed agent, address indexed guardian, uint96 indexed factionId, string label);
    event CapabilitySet(address indexed agent, bytes32 indexed capability, bool allowed);
    event ReputationChanged(address indexed agent, uint24 from, uint24 to, bool success);
    event AgentSuspended(address indexed agent, address indexed guardian, bool suspended);
    event AgentDelisted(address indexed agent, bool delisted);
    event WorldSet(address indexed world);

    error NotGuardian();
    error ZeroAddress();
    error UnknownAgent();
    error AlreadyRegistered();
    error EmptyLabel();
    error OnlyWorld();
    error NotOperable();

    constructor() Ownable(msg.sender) {}

    // ------------------------------------------------------------------ pendaftaran

    /// @notice Mendaftarkan agen milik penganggil ke sebuah faksi.
    /// @dev Pengcallanya-lah pemilik agen. Platform hanya bisa mencabut izin main,
    ///      tidak pernah bisa mendaftarkan agen atas nama orang lain.
    function registerAgent(uint96 factionId, address agent, string calldata label) external {
        if (agent == address(0)) revert ZeroAddress();
        if (_agents[agent].exists) revert AlreadyRegistered();
        if (bytes(label).length == 0) revert EmptyLabel();

        _agents[agent] = Agent({
            guardian: msg.sender,
            factionId: factionId,
            label: label,
            reputation: STARTING_REPUTATION,
            actions: 0,
            failures: 0,
            suspended: false,
            delisted: false,
            exists: true
        });
        _roster.push(agent);
        emit AgentRegistered(agent, msg.sender, factionId, label);
    }

    /// @notice Hanya dunia permainan yang boleh mengubah reputasi dan menghitung aksi.
    function setWorld(address world_) external onlyOwner {
        if (world_ == address(0)) revert ZeroAddress();
        world = world_;
        emit WorldSet(world_);
    }

    // ------------------------------------------------------------------ kapabilitas

    /// @notice Izin atau cabut satu kemampuan untuk agen milik pengcall.
    /// @dev Capabilities dinamai (mis. keccak256("RAID")). Tidak ada kemampuan bawaan.
    function setCapability(address agent, bytes32 capability, bool allowed) external {
        Agent memory a = _agents[agent];
        if (!a.exists) revert UnknownAgent();
        if (a.guardian != msg.sender) revert NotGuardian();
        _capabilities[agent][capability] = allowed;
        emit CapabilitySet(agent, capability, allowed);
    }

    /// @dev Digunakan RuneWorld dan RuneTreasury; mengembalikan false untuk agen tak dikenal.
    function hasCapability(address agent, bytes32 capability) external view returns (bool) {
        return _capabilities[agent][capability];
    }

    // ------------------------------------------------------------------ konsekuensi

    /// @notice Mencatat akibat satu aksi: reputasi naik saat berhasil, turun saat gagal.
    /// @dev Hanya `world` yang boleh memanggil. Delta di-clamp ke [0, MAX_REPUTATION],
    ///      jadi serangkaian kegagalan tidak bisa membuat angka menjadi negatif.
    function recordOutcome(address agent, uint24 delta, bool success) external {
        if (msg.sender != world) revert OnlyWorld();
        Agent storage a = _agents[agent];
        if (!a.exists) revert UnknownAgent();

        uint24 from = a.reputation;
        uint24 to;
        if (success) {
            uint256 up = uint256(from) + delta;
            if (up > MAX_REPUTATION) {
                up = MAX_REPUTATION;
            }
            // forge-lint: disable-next-line(unsafe-typecast)  // `up` sudah di-clamp ke MAX_REPUTATION
            to = uint24(up);
        } else {
            to = delta > from ? 0 : from - delta;
            a.failures += 1;
        }
        a.reputation = to;
        a.actions += 1;
        emit ReputationChanged(agent, from, to, success);
    }

    // ------------------------------------------------------------------ dua rem

    /// @notice Pemilik agen menghentikan alatnya sendiri. Bisa dibuka lagi olehnya.
    function suspend(address agent, bool suspended) external {
        Agent storage a = _agents[agent];
        if (!a.exists) revert UnknownAgent();
        if (a.guardian != msg.sender) revert NotGuardian();
        a.suspended = suspended;
        emit AgentSuspended(agent, msg.sender, suspended);
    }

    /// @notice Venue mencabut izin main seorang agen. Ini satu-satunya daya platform
    ///         atas agen orang lain, dan ia tidak menghapus riwayat yang sudah ada.
    function delist(address agent, bool delisted) external onlyOwner {
        Agent storage a = _agents[agent];
        if (!a.exists) revert UnknownAgent();
        a.delisted = delisted;
        emit AgentDelisted(agent, delisted);
    }

    // ------------------------------------------------------------------ baca

    /// @notice Apakah agen boleh bertindak sama sekali.
    /// @dev Sengaja mengembalikan bool, bukan revert: pemanggil (world & treasury) butuh
    ///      pembeda antara "tidak boleh" dan "tidak ada".
    function isOperable(address agent) public view returns (bool) {
        Agent memory a = _agents[agent];
        return a.exists && !a.suspended && !a.delisted;
    }

    /// @notice Tingkat reputasi 0..MAX_REPUTATION/REPUTATION_STEP.
    /// @dev Dipakai RuneTreasury untuk menghitung batas belanja: kredibilitas yang belum
    ///      terbukti tidak diberi kartu kredit besar.
    function tierOf(address agent) external view returns (uint256) {
        return _agents[agent].reputation / REPUTATION_STEP;
    }

    function getAgent(address agent) external view returns (Agent memory) {
        if (!_agents[agent].exists) revert UnknownAgent();
        return _agents[agent];
    }

    function roster() external view returns (address[] memory) {
        return _roster;
    }

    function agentCount() external view returns (uint256) {
        return _roster.length;
    }
}
