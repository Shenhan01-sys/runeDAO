// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RuneRegistry} from "../contracts/RuneRegistry.sol";
import {RuneTreasury} from "../contracts/RuneTreasury.sol";
import {RuneWorld} from "../contracts/RuneWorld.sol";

/// Deploy runeDAO ke BSC testnet (chainId 97) dan menyiapkan dunia yang benar-benar bisa
/// dimainkan agen.
///
/// Urutannya bukan hiasan. `Treasury` butuh alamat `Registry`, `World` butuh keduanya, dan
/// `Registry.setWorld(world)` baru boleh terjadi SETELAH world ada — kalau tidak, world jadi
/// alamat nol dan satu-satunya jalur perubahan reputasi tertutup permanen.
///
/// Tiga faksi, tiga guardian, tiga agen: jumlah terkecil yang masih membuktikan klaim
/// "agen milik pihak lain" (satu faksi cuma membuktikan kami bisa menjalankan sendiri).
///
/// Idempoten sebagian: faction & region yang sudah ada dilewati, jadi run ulang setelah
/// kegagalan tidak menabrak `AlreadyExists`.
contract Deploy is Script {
    uint96 internal constant FACTION_COUNT = 3;
    uint96 internal constant REGION_COUNT = 6;

    /// @notice Gas yang dikirim ke tiap wallet supaya agen benar-benar bisa menyiarkan sendiri.
    ///         Angka ini hasil bagi, bukan kira-kira: satu aksi agen ±300k gas, dan di 3 gwei
    ///         itu ~0,0000009 BNB. 0,0002 BNB = ratusan aksi. Sengaja kecil: kalau kunci agen
    ///         bocor, kerugian maksimal segini.
    /// @dev Total aliran keluar = 3 × (0,0004 + 0,0002 + 0,002) = 0,0078 BNB. Deployer 97
    ///      memegang ~0,0141 BNB, dan simulasi pertama gagal di faksi C dengan `OutOfFunds`
    ///      saat angkanya masih 0,0008 / 0,0004 / 0,004 — tercatat di sini supaya penurunannya
    ///      tidak dibalikkan orang berikutnya tanpa sadar.
    uint256 internal constant GUARDIAN_STIPEND = 0.0004 ether;
    uint256 internal constant AGENT_STIPEND = 0.0002 ether;
    uint256 internal constant FACTION_DEPOSIT = 0.0015 ether;
    /// @notice Hadiah awal tiap wilayah = 2x biaya satu raid. Lihat alasannya di RuneWorld.seedRegion.
    uint96 internal constant BASE_BOUNTY = 0.0004 ether;

    string[6] internal REGIONS = ["Vhal'Mor", "Abu Kelabu", "Rawa Gema", "Pintu Garam", "Tulang Raja", "Simpul Asing"];

    RuneRegistry internal registry;
    RuneTreasury internal treasury;
    RuneWorld internal world;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("deployer:");
        console.logAddress(deployer);

        vm.startBroadcast(deployerKey);
        registry = new RuneRegistry();
        treasury = new RuneTreasury(address(registry));
        world = new RuneWorld(address(registry), address(treasury));
        registry.setWorld(address(world));
        vm.stopBroadcast();

        _seedWorld(deployerKey);

        for (uint96 i = 0; i < FACTION_COUNT; i++) {
            _openFaction(i, deployerKey);
        }

        console.log("REGISTRY_ADDRESS");
        console.logAddress(address(registry));
        console.log("TREASURY_ADDRESS");
        console.logAddress(address(treasury));
        console.log("WORLD_ADDRESS");
        console.logAddress(address(world));
        console.log("sisa saldo deployer (ribuan BNB testnet):");
        console.logUint(deployer.balance / 1e15);
    }

    function _seedWorld(uint256 deployerKey) internal {
        vm.startBroadcast(deployerKey);
        for (uint96 i = 0; i < REGION_COUNT; i++) {
            try world.getRegion(i) {
                console.log("  region sudah ditabur, dilewati: id");
                console.logUint(i);
            } catch {
                world.seedRegion{value: BASE_BOUNTY}(i, REGIONS[i], 20, BASE_BOUNTY);
                console.log("  seeded region id / nama:");
                console.logUint(i);
                console.logString(REGIONS[i]);
            }
        }
        vm.stopBroadcast();
    }

    function _openFaction(uint96 index, uint256 deployerKey) internal {
        uint96 factionId = index + 1;
        string memory tag = _tag(index);

        address guardian = vm.envAddress(string(abi.encodePacked("FACTION_", tag, "_GUARDIAN_ADDRESS")));
        uint256 guardianKey = vm.envUint(string(abi.encodePacked("FACTION_", tag, "_GUARDIAN_PRIVATE_KEY")));
        uint256 agentKey = vm.envUint(string(abi.encodePacked("FACTION_", tag, "_AGENT_PRIVATE_KEY")));
        address agent = vm.addr(agentKey);

        // Guardian dibiayai deployer lebih dulu: tanpanya dia tidak bisa createFaction, dan
        // tanpa faksi agen tidak punya kas untuk dibelanjakan.
        if (guardian.balance < GUARDIAN_STIPEND) {
            vm.startBroadcast(deployerKey);
            payable(guardian).transfer(GUARDIAN_STIPEND);
            vm.stopBroadcast();
        }

        vm.startBroadcast(guardianKey);
        if (!treasury.factionExists(factionId)) {
            treasury.createFaction(factionId);
        }
        treasury.setPolicy(factionId, 0.0005 ether, 0.002 ether, 0);
        treasury.setTarget(factionId, address(world), true);
        if (!_alreadyRegistered(agent)) {
            registry.registerAgent(factionId, agent, string(abi.encodePacked("agent-", tag)));
        }
        registry.setCapability(agent, keccak256("RAID"), true);
        registry.setCapability(agent, keccak256("ENTRENCH"), true);
        if (agent.balance < AGENT_STIPEND) {
            payable(agent).transfer(AGENT_STIPEND);
        }
        vm.stopBroadcast();

        // Setoran kas faksi: 0,002 ether = enam raid penuh (0,0003 per raid), dan itu memang
        // sama dengan plafon hariannya — jadi kas tidak pernah jadi penghalang, gerbang hari
        // yang jadi penghalang. Itu yang mau ditunjukkan demo.
        vm.startBroadcast(deployerKey);
        treasury.deposit{value: FACTION_DEPOSIT}(factionId);
        vm.stopBroadcast();

        console.log("faction id");
        console.logUint(factionId);
        console.log("guardian");
        console.logAddress(guardian);
        console.log("agent");
        console.logAddress(agent);
    }

    /// `getAgent` revert untuk address tak terdaftar; try/catch dipakai supaya run ulang
    /// script ini tidak mati di `AlreadyRegistered`.
    function _alreadyRegistered(address agent) internal view returns (bool) {
        try registry.getAgent(agent) returns (RuneRegistry.Agent memory) {
            return true;
        } catch {
            return false;
        }
    }

    function _tag(uint96 index) internal pure returns (string memory) {
        if (index == 0) return "A";
        if (index == 1) return "B";
        return "C";
    }
}
