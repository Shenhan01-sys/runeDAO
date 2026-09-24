// Tanya ke kontrak yang HIDUP: fungsi ini ada atau tidak?
//
// Kenapa alat ini ada: source dan chain bisa berbeda, dan satu-satunya yang boleh menjawab
// pertanyaan itu adalah chain. Versi pertama alat ini salah simpul dua kali:
//   - memanggil fungsi BERSYARAT tanpa argumen -> `deposit(uint96)` yang memang ADA membalas
//     revert (faksi 0 tak dikenal), tak terbedakan dari fungsi yang absen;
//   - mengira "reverted" = ada. Padahal revert TANPA selector adalah persis cara BSC menjawab
//     fungsi yang tidak ada.
// Karena itu sekarang ada KONTROL NEGATIF: fungsi fiktif yang pasti tidak pernah kita deploy.
// Balasan kontrol itulah penggarisnya.
//
//   node tools/probe-surface.mjs

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { createPublicClient, encodeFunctionData, http, parseAbi } from "viem";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const env = Object.fromEntries(
  readFileSync(join(ROOT, ".env"), "utf8")
    .split(/\r?\n/)
    .filter((l) => l.includes("=") && !l.startsWith("#"))
    .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1).trim()]),
);

const client = createPublicClient({ transport: http(env.RPC_URL || "https://bsc-testnet.publicnode.com") });

const WORLD_ABI = parseAbi([
  "function CONTROL_DOES_NOT_EXIST() view returns (uint32)",
  "function MIN_STRENGTH() view returns (uint32)",
  "function LOOT_SHARE_PERCENT() view returns (uint256)",
  "function REGION_COUNT() view returns (uint96)",
  "function actionCount() view returns (uint256)",
]);
const TREASURY_ABI = parseAbi([
  "function CONTROL_DOES_NOT_EXIST() view returns (uint32)",
  "function factionExists(uint96) view returns (bool)",
  "function HARD_DAILY_CAP() view returns (uint96)",
  "function withdraw(uint96,uint96)",
]);

// Semua pertanyaan dikirim sebagai eth_call mentah (bukan readContract): readContract menolak
// fungsi non-view, sedangkan yang justru ingin kita uji (withdraw) memang non-view. Yang
// dibandingkan adalah REVERSNYA: tanpa selector = fungsi tidak dikenal; dengan selector error
// kustom = fungsinya ada dan menolak karena alasan yang sah (mis. NotGuardian).
async function probe(addr, abi, fn, args = []) {
  try {
    const data = encodeFunctionData({ abi, functionName: fn, args });
    const res = await client.call({ to: addr, data });
    return { kind: "ADA", detail: String(res).slice(0, 40) };
  } catch (e) {
    const msg = String(e?.shortMessage ?? e?.message ?? e);
    const m = msg.match(/0x[0-9a-fA-F]{8}/);
    if (m) return { kind: "ADA", detail: `menolak dengan error ${m[0]}` };
    return { kind: "TIDAK ADA", detail: msg.split("\n")[0].slice(0, 60) };
  }
}

async function section(title, addr, abi, calls) {
  console.log(`\n${title}  ${addr}`);
  const control = await probe(addr, abi, "CONTROL_DOES_NOT_EXIST");
  console.log(`  ${"CONTROL_DOES_NOT_EXIST".padEnd(24)} ${control.kind}   <-- penggaris`);
  for (const [fn, args] of calls) {
    const r = await probe(addr, abi, fn, args);
    const same = r.kind === control.kind;
    console.log(`  ${fn.padEnd(24)} ${r.kind}${same ? "   (persis seperti kontrol)" : `  -> ${r.detail}`}`);
  }
}

await section("world", env.WORLD_ADDRESS, WORLD_ABI, [
  ["REGION_COUNT", []],
  ["actionCount", []],
  ["MIN_STRENGTH", []],
  ["LOOT_SHARE_PERCENT", []],
]);

await section("treasury", env.TREASURY_ADDRESS, TREASURY_ABI, [
  ["HARD_DAILY_CAP", []],
  ["factionExists", [1n]],
  ["withdraw", [1n, 1n]],
]);

console.log("\n=== pembacaan ===");
console.log("fungsi yang balasannya identik dengan kontrol TIDAK ada di kontrak yang hidup,");
console.log("sekalipun ada di source — artinya source mendahului chain dan klaim harus begitu");
console.log("dijelaskan, bukan dibisikkan.");
