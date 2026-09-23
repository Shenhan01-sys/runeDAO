// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RuneTreasury} from "../contracts/RuneTreasury.sol";
import {RuneWorld} from "../contracts/RuneWorld.sol";

/// Isi ulang daya agen dan kas faksi, dengan angka yang diukur bukan ditebak.
///
/// `eth_gasPrice` chain 97 terukur 0,1 gwei dan satu aksi penuh (commit + resolve) habis
/// ~370k gas = 0,000037 BNB. Angka itu yang menentukan berapa banyak aksi bisa dilakukan
/// seorang agen tanpa butuh manusia — jadi ia ditulis di sini, bukan di kepala.
///
///   forge script script/Fund.s.sol --rpc-url https://bsc-testnet.publicnode.com --broadcast
contract Fund is Script {
    /// @notice BNB gas per wallet agen. 0,001 = ~27 aksi penuh pada 0,1 gwei.
    uint256 internal constant AGENT_GAS_TARGET = 0.001 ether;
    /// @notice Sasaran kas faksi. Dibuat tidak lebih tinggi dari plafon harian efektif
    ///     (0,002 dasar x bonus reputasi) supaya "kas" tidak pernah yang membatasi.
    uint256 internal constant FACTION_CASH_TARGET = 0.003 ether;

    function run() external {
        RuneTreasury treasury = RuneTreasury(vm.envAddress("TREASURY_ADDRESS"));
        RuneWorld world = RuneWorld(payable(vm.envAddress("WORLD_ADDRESS")));
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(key);

        console.log("deployer");
        console.logAddress(deployer);
        console.log("saldo awal (wei)", deployer.balance);

        vm.startBroadcast(key);

        for (uint96 idx = 0; idx < 3; idx++) {
            string memory tag = idx == 0 ? "A" : (idx == 1 ? "B" : "C");
            uint96 factionId = idx + 1;
            address agent = vm.envAddress(string(abi.encodePacked("FACTION_", tag, "_AGENT_ADDRESS")));

            if (agent.balance < AGENT_GAS_TARGET) {
                uint256 topup = AGENT_GAS_TARGET - agent.balance;
                payable(agent).transfer(topup);
                console.log("topup gas untuk faction", factionId);
                console.log("  (wei)", topup);
            }

            RuneTreasury.Faction memory f = treasury.getFaction(factionId);
            uint256 need = FACTION_CASH_TARGET > f.balance ? FACTION_CASH_TARGET - f.balance : 0;
            if (need > 0 && deployer.balance > need) {
                treasury.deposit{value: need}(factionId);
                console.log("topup kas faksi", factionId);
                console.log("  (wei)", need);
            }
        }

        vm.stopBroadcast();

        console.log("saldo akhir deployer (wei)", deployer.balance);
        console.log("kas treasury (wei)", address(treasury).balance);
        console.log("kas world (wei)", address(world).balance);
    }
}
