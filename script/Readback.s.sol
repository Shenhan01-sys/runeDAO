// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RuneRegistry} from "../contracts/RuneRegistry.sol";
import {RuneTreasury} from "../contracts/RuneTreasury.sol";
import {RuneWorld} from "../contracts/RuneWorld.sol";

/// Baca ulang deployment dari chain dan tagih klaimnya.
///
/// Ini bukan logger "berhasil deploy": dia memanggil kontrak yang SUDAH ada di alamat .env dan
/// membandingkan apa yang dikatakannya dengan apa yang seharusnya. Karena itu dia menagih dua
/// hal yang paling biasa bohong:
///   - "rantai otoritas terpasang" (registry -> world, treasury -> registry), dan
///   - "agen boleh belanja" (kapabilitas + target + plafon efektif setelah bonus reputasi).
///
/// Jalankan tanpa menyiarkan apa pun:
///   forge script script/Readback.s.sol --rpc-url https://bsc-testnet.publicnode.com
contract Readback is Script {
    uint96 internal constant FACTION_COUNT = 3;

    function run() external view {
        RuneRegistry registry = RuneRegistry(payable(vm.envAddress("REGISTRY_ADDRESS")));
        RuneTreasury treasury = RuneTreasury(vm.envAddress("TREASURY_ADDRESS"));
        RuneWorld world = RuneWorld(payable(vm.envAddress("WORLD_ADDRESS")));

        console.log("=== alamat dari .env, dipakai sebagai kontrak ===");
        console.log("Registry");
        console.logAddress(address(registry));
        console.log("Treasury");
        console.logAddress(address(treasury));
        console.log("World");
        console.logAddress(address(world));

        console.log("");
        console.log("=== rantai otoritas ===");
        console.log("  Registry.world() == World      ", registry.world() == address(world));
        console.log("  Treasury.REGISTRY() == Registry", address(treasury.REGISTRY()) == address(registry));
        console.log("  World.REGISTRY() == Registry   ", address(world.REGISTRY()) == address(registry));
        console.log("  World.TREASURY() == Treasury   ", address(world.TREASURY()) == address(treasury));

        console.log("");
        console.log("=== dunia ===");
        console.log("  jumlah wilayah", world.REGION_COUNT());
        for (uint96 i = 0; i < world.REGION_COUNT(); i++) {
            RuneWorld.Region memory r = world.getRegion(i);
            console.log("  region", i);
            console.log("    nama", r.name);
            console.log("    faction pemilik", r.owner);
            console.log("    kekuatan", r.strength);
            console.log("    pool (wei)", r.pool);
            console.log("    threshold raid", world.raidThreshold(i));
            console.log("    lastActed", r.lastActed);
        }

        console.log("");
        console.log("=== faksi, agen, dan apa yang boleh dibelanjakan ===");
        for (uint96 idx = 0; idx < FACTION_COUNT; idx++) {
            uint96 factionId = idx + 1;
            string memory tag = idx == 0 ? "A" : (idx == 1 ? "B" : "C");
            address agent = vm.envAddress(string(abi.encodePacked("FACTION_", tag, "_AGENT_ADDRESS")));
            address guardian = vm.envAddress(string(abi.encodePacked("FACTION_", tag, "_GUARDIAN_ADDRESS")));

            console.log("  faction", factionId);
            if (!treasury.factionExists(factionId)) {
                console.log("    TIDAK ADA di chain");
                continue;
            }

            RuneTreasury.Faction memory f = treasury.getFaction(factionId);
            console.log("    guardian cocok dengan .env", f.guardian == guardian);
            console.log("    saldo faksi (wei)", f.balance);
            console.log("    totalSpent (wei)", f.totalSpent);
            console.log("    jumlah belanja", f.spends);
            console.log("    frozen", f.frozen);

            bool known = true;
            try registry.getAgent(agent) returns (RuneRegistry.Agent memory a) {
                console.log("    agen terdaftar", true);
                console.log("    factionId agen cocok", a.factionId == factionId);
                console.log("    reputasi", a.reputation);
                console.log("    tier", registry.tierOf(agent));
                console.log("    aksi / gagal", a.actions);
                console.log("    operable", registry.isOperable(agent));
            } catch {
                known = false;
                console.log("    agen TIDAK terdaftar");
            }
            if (!known) {
                continue;
            }

            console.log("    cap RAID", registry.hasCapability(agent, world.KIND_RAID()));
            console.log("    cap ENTRENCH", registry.hasCapability(agent, world.KIND_ENTRENCH()));
            console.log("    World jadi target diizinkan", treasury.isTargetAllowed(factionId, address(world)));

            (uint96 perAction, uint96 daily) = treasury.effectiveCaps(agent);
            console.log("    plafon efektif per aksi (wei)", perAction);
            console.log("    plafon efektif per hari (wei)", daily);
            console.log("    biaya RAID (wei)", world.RAID_COST());
            console.log("    raid penuh per hari", daily / world.RAID_COST());
        }
    }
}
