// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RuneRegistry} from "../contracts/RuneRegistry.sol";
import {RuneTreasury} from "../contracts/RuneTreasury.sol";
import {RuneWorld} from "../contracts/RuneWorld.sol";

/// Ganti kontrak World saja, tanpa menyentuh Registry/Treasury.
///
/// Kenapa boleh: `RuneTreasury.spend()` membaca `REGISTRY.world()` SETIAP kali memanggil, jadi
/// otorisasi dunia tidak dipaku ke alamat — dan karena itu kas faksi tetap utuh di treasury
/// lama (0,009 BNB testnet) sementara aturan permainan yang baru dipakai.
///
/// Kenapa perlu: `RuneWorld` pertama tidak punya `abandon()`. Tanpa itu, satu commit yang
/// tidak diselesaikan mengunci agennya selamanya — `commit()` berikutnya selalu
/// `CommitAlreadyOpen`. Ini jalur pemulihan yang sah, bukan alasan untuk deploy ulang tanpa
/// sebab: state wilayah memang direset (semua netral, pool nol) dan itu disengaja.
///
///   forge script script/ReplaceWorld.s.sol --rpc-url ... --broadcast
contract ReplaceWorld is Script {
    string[6] internal REGIONS = ["Vhal'Mor", "Abu Kelabu", "Rawa Gema", "Pintu Garam", "Tulang Raja", "Simpul Asing"];
    /// @notice Hadiah awal tiap wilayah. Tanpa ini wilayah baru berhadiah 0 dan EV
    ///     menyerang selalu negatif, jadi dunia lahir beku - yang terukur terjadi musim lalu.
    uint256 internal constant BASE_BOUNTY = 0.0004 ether;
    function run() external {
        RuneRegistry registry = RuneRegistry(payable(vm.envAddress("REGISTRY_ADDRESS")));
        RuneTreasury treasury = RuneTreasury(vm.envAddress("TREASURY_ADDRESS"));
        address oldWorld = vm.envAddress("WORLD_ADDRESS");
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console.log("world lama");
        console.logAddress(oldWorld);

        vm.startBroadcast(key);
        RuneWorld world = new RuneWorld(address(registry), address(treasury));
        registry.setWorld(address(world));
        for (uint96 i = 0; i < 6; i++) {
            world.seedRegion{value: BASE_BOUNTY}(i, REGIONS[i], 20, uint96(BASE_BOUNTY));
        }
        vm.stopBroadcast();

        // Setiap guardian harus mengizinkan dunia baru sebagai penerima dana; tanpa ini
        // gerbang `allowedTarget` kas faksi tetap menunjuk world lama dan belanja agen revert.
        for (uint96 idx = 0; idx < 3; idx++) {
            string memory tag = idx == 0 ? "A" : (idx == 1 ? "B" : "C");
            uint256 gkey = vm.envUint(string(abi.encodePacked("FACTION_", tag, "_GUARDIAN_PRIVATE_KEY")));
            vm.startBroadcast(gkey);
            treasury.setTarget(idx + 1, address(world), true);
            vm.stopBroadcast();
        }

        console.log("world baru");
        console.logAddress(address(world));
        console.log("saldo deployer sisa (wei)", payable(vm.addr(key)).balance);
        console.log("registry menunjuk world baru:", registry.world() == address(world));
    }
}
