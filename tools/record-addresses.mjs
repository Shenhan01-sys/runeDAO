// Rekam address kontrak ke .env — dibaca dari CHAIN, bukan dari asumsi urutan file.
//
//   node tools/record-addresses.mjs
//
// Kenapa tidak sekadar membaca broadcast/Deploy.s.sol/97/run-latest.json: world bisa DIGANTI
// (script/ReplaceWorld.s.sol) tanpa mengganti registry/treasury. Versi naif dari alat ini akan
// menulis ulang WORLD_ADDRESS ke world pertama yang sudah tidak berkuasa — sebuah bug yang
// tidak kelihatan sampai agen mulai revert. Jadi:
//   • REGISTRY/TREASURY diambil dari CREATE file deploy awal;
//   • WORLD diambil dari CREATE TERAKHIR di seluruh riwayat broadcast, dan itu dilakukan lewat
//     scanning, bukan hardcode;
//   • setiap address diverifikasi punya bytecode di chain sebelum ditulis.
//
// Catatan yang sudah menggigit: `transactionIndex` TIDAK bisa dipakai sebagai urutan (foundry
// mengisi nilai yang sama untuk banyak entri), jadi urutan diambil dari kemunculan CREATE.

import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { createPublicClient, http } from "viem";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const ENV = join(ROOT, ".env");
const RPC = process.env.RPC_URL || "https://bsc-testnet.publicnode.com";
const BROADCAST = join(ROOT, "broadcast");

function envVals() {
  const out = {};
  if (!existsSync(ENV)) return out;
  for (const line of readFileSync(ENV, "utf8").split(/\r?\n/)) {
    const t = line.trim();
    if (t && !t.startsWith("#") && t.includes("=")) {
      const i = t.indexOf("=");
      out[t.slice(0, i).trim()] = t.slice(i + 1).trim();
    }
  }
  return out;
}

function runFiles(dir) {
  const out = [];
  if (!existsSync(dir)) return out;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...runFiles(p));
    } else if (entry.name.startsWith("run-") && entry.name.endsWith(".json")) {
      out.push(p);
    }
  }
  return out;
}

const files = runFiles(BROADCAST).map((f) => {
  const data = JSON.parse(readFileSync(f, "utf8"));
  return {
    file: f,
    timestamp: data.timestamp ?? 0,
    creates: (data.transactions ?? []).filter((t) => t.transactionType === "CREATE").map((t) => t.contractAddress),
  };
});

if (!files.length) {
  console.error("tidak ada riwayat broadcast sama sekali — jalankan script/Deploy.s.sol dulu");
  process.exit(1);
}

const byTime = [...files].sort((a, b) => a.timestamp - b.timestamp);
const withCreate = byTime.filter((f) => f.creates.length > 0);
if (!withCreate.length) {
  console.error("tidak ada satu pun riwayat broadcast yang memuat CREATE");
  process.exit(1);
}
const first = withCreate[0];
// registry & treasury diambil dari run yang sama dan HARUS memuat >=3 CREATE (bring-up penuh);
// world diambil dari CREATE terakhir secara keseluruhan. Aturan ini perlu karena run dunia-baru
// hanya punya SATU CREATE: kalau treasury ikut diambil dari run itu, treasury lama (yang masih
// memegang kas faksi) tertimpa alamat world.
const full = withCreate.find((f) => f.creates.length >= 3);
if (!full) {
  console.error("tidak ada run yang memuat 3 CREATE - jalankan script/Deploy.s.sol dulu");
  process.exit(1);
}
const last = withCreate[withCreate.length - 1];

if (first.creates.length < 3) {
  console.error(`deploy awal hanya memuat ${first.creates.length} CREATE: ${first.file}`);
  process.exit(1);
}

const found = {
  REGISTRY_ADDRESS: first.creates[0],
  TREASURY_ADDRESS: first.creates[1],
  WORLD_ADDRESS: last.creates[last.creates.length - 1],
};

const client = createPublicClient({ transport: http(RPC) });
console.log(`chain: ${RPC}`);

const checked = [];
for (const [name, addr] of Object.entries(found)) {
  if (!addr || !/^0x[0-9a-fA-F]{40}$/.test(addr)) {
    console.error(`${name}: bukan address valid (${addr}) — berhenti, tidak menulis apa pun`);
    process.exit(1);
  }
  const code = await client.getBytecode({ address: addr });
  const bytes = code ? (code.length - 2) / 2 : 0;
  if (bytes === 0) {
    console.error(`${name}: ${addr} tidak punya bytecode — berhenti, address tidak ditulis`);
    process.exit(1);
  }
  checked.push([name, addr, bytes]);
  console.log(`  ${name.padEnd(18)} ${addr}  ${bytes} byte code`);
}

if (found.WORLD_ADDRESS !== first.creates[2]) {
  console.log("  (world yang dicatat BUKAN world dari deploy awal — sumber terbaru dipakai)");
}

let env = readFileSync(ENV, "utf8");
for (const [k, v] of checked) {
  const re = new RegExp(`^${k}=.*$`, "m");
  env = re.test(env) ? env.replace(re, `${k}=${v}`) : `${env.trimEnd()}\n${k}=${v}\n`;
}
writeFileSync(ENV, env, { encoding: "utf8", mode: 0o600 });
console.log("ditulis ke .env (nilai kunci tidak disentuh)");
