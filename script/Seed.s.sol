// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RuneWorld} from "../contracts/RuneWorld.sol";

/// Tabur wilayah dunia yang sudah ada. Idempoten: yang sudah ditabur dilewati.
///
/// Terpisah dari Deploy.s.sol karena dunia bisa diganti (lihat ReplaceWorld.s.sol) tanpa
/// mengganti registry/treasury — dan dunia baru lahir kosong: `getRegion` revert, agen tidak
/// bisa apa-apa. Digabung ke script deploy lama akan membuat script itu tidak bisa dipakai
/// lagi untuk tujuan yang berbeda.
///
///   forge script script/Seed.s.sol --rpc-url https://bsc-testnet.publicnode.com --broadcast
contract Seed is Script {
    string[6] internal NAMES = ["Vhal'Mor", "Abu Kelabu", "Rawa Gema", "Pintu Garam", "Tulang Raja", "Simpul Asing"];
    uint32 internal constant START_STRENGTH = 20;
    /// @notice Hadiah awal tiap wilayah; tanpa ini wilayah baru berhadiah 0 dan EV menyerang selalu negatif.
    uint96 internal constant BASE_BOUNTY = 0.0004 ether;

    function run() external {
        RuneWorld world = RuneWorld(payable(vm.envAddress("WORLD_ADDRESS")));
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console.log("world");
        console.logAddress(address(world));

        uint256 seeded = 0;
        for (uint96 i = 0; i < world.REGION_COUNT(); i++) {
            bool exists = true;
            try world.getRegion(i) {
                exists = true;
            } catch {
                exists = false;
            }
            if (exists) {
                console.log("  sudah ada, dilewati: region");
                console.logUint(i);
                continue;
            }
            vm.startBroadcast(key);
            world.seedRegion{value: BASE_BOUNTY}(i, NAMES[i], START_STRENGTH, BASE_BOUNTY);
            vm.stopBroadcast();
            console.log("  ditabur: region");
            console.logUint(i);
            console.log("    nama", NAMES[i]);
            seeded += 1;
        }
        console.log("jumlah wilayah ditabur");
        console.logUint(seeded);
    }
}
