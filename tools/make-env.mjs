// Bangun runeDAO/.env dengan kunci burner testnet yang BARU.
//
// Idempoten: kunci yang sudah ada tidak pernah ditimpa, jadi wallet yang sudah memegang kas
// faksi tidak hilang kalau script ini jalan dua kali.
//
// Nilai kunci tidak pernah dicetak ke stdout — yang dicetak hanya address. Alasannya praktis:
// log sesi dan terminal punya kebiasaan panjang umurnya dibanding kunci.
//
//   node tools/make-env.mjs

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const OUT = join(ROOT, ".env");

const ROLES = [];
for (const tag of ["A", "B", "C"]) {
  ROLES.push(`FACTION_${tag}_GUARDIAN`, `FACTION_${tag}_AGENT`);
}

function existing() {
  const out = {};
  if (!existsSync(OUT)) return out;
  for (const line of readFileSync(OUT, "utf8").split(/\r?\n/)) {
    const t = line.trim();
    if (t && !t.startsWith("#") && t.includes("=")) {
      const i = t.indexOf("=");
      out[t.slice(0, i).trim()] = t.slice(i + 1).trim();
    }
  }
  return out;
}

const have = existing();
const created = [];
const vals = {
  CHAIN_ID: have.CHAIN_ID ?? "97",
  RPC_URL: have.RPC_URL ?? "https://bsc-testnet.publicnode.com",
  RPC_URL_ALT: have.RPC_URL_ALT ?? "https://bsc-testnet-rpc.publicnode.com",
};

// Deployer: platform owner. Kalau .env sudah punya, pertahankan; kalau belum, kunci baru.
// (Di pengembangan awal, deployer sengaja dipakai bersama dengan proyek lain di mesin ini.
// Untuk deployment baru, jalankan dengan --fresh-deployer untuk memisahkannya.)
if (have.DEPLOYER_PRIVATE_KEY) {
  vals.DEPLOYER_PRIVATE_KEY = have.DEPLOYER_PRIVATE_KEY;
  vals.DEPLOYER_ADDRESS = have.DEPLOYER_ADDRESS ?? privateKeyToAccount(have.DEPLOYER_PRIVATE_KEY).address;
} else if (process.argv.includes("--fresh-deployer")) {
  const k = generatePrivateKey();
  vals.DEPLOYER_PRIVATE_KEY = k;
  vals.DEPLOYER_ADDRESS = privateKeyToAccount(k).address;
  created.push("DEPLOYER");
} else {
  console.error("Tidak ada DEPLOYER_PRIVATE_KEY. Jalankan ulang dengan --fresh-deployer untuk");
  console.error("membangun wallet deployer baru, atau isi sendiri kalau kamu memang memakainya");
  console.error("bersama dengan proyek lain di mesin ini.");
  process.exit(1);
}

for (const role of ROLES) {
  const kkey = `${role}_PRIVATE_KEY`;
  const akey = `${role}_ADDRESS`;
  if (have[kkey]) {
    vals[kkey] = have[kkey];
    vals[akey] = have[akey] ?? privateKeyToAccount(have[kkey]).address;
    continue;
  }
  const k = generatePrivateKey();
  vals[kkey] = k;
  vals[akey] = privateKeyToAccount(k).address;
  created.push(role);
}

for (const k of ["REGISTRY_ADDRESS", "TREASURY_ADDRESS", "WORLD_ADDRESS"]) vals[k] = have[k] ?? "";

const header = [
  "# runeDAO — kunci BURNER untuk BSC testnet (chainId 97).",
  "# Jangan di-commit. Jangan dipakai di mainnet. Jangan dipakai untuk apa pun selain proyek ini.",
  "# Dibangun oleh: node tools/make-env.mjs [--fresh-deployer]",
  "",
];

// Setiap baris harus `KUNCI=nilai`. Versi pertama file ini melakukan `lines.push(k)` untuk blok
// atas, sehingga "CHAIN_ID", "RPC_URL" dan dua baris DEPLOYER mendarat sebagai teks telanjang
// tanpa tanda sama dengan — hilang saat dibaca ulang. Preflight dengan backup menangkap itu.
const ORDER = [
  "CHAIN_ID",
  "RPC_URL",
  "RPC_URL_ALT",
  null,
  "DEPLOYER_ADDRESS",
  "DEPLOYER_PRIVATE_KEY",
  null,
  ...ROLES.flatMap((r) => [`${r}_ADDRESS`, `${r}_PRIVATE_KEY`, null]),
  null,
  "REGISTRY_ADDRESS",
  "TREASURY_ADDRESS",
  "WORLD_ADDRESS",
];

const lines = [...header];
for (const k of ORDER) {
  if (k === null) {
    lines.push("");
    continue;
  }
  lines.push(`${k}=${vals[k] ?? ""}`);
}
lines.push("");
lines.push("# REGISTRY/TREASURY/WORLD diisi dari riwayat deploy: node tools/record-addresses.mjs");

writeFileSync(OUT, lines.join("\n") + "\n", { encoding: "utf8", mode: 0o600 });

console.log(`.env ditulis: ${OUT}`);
console.log(`kunci baru dibuat: ${created.length ? created.join(", ") : "tidak ada (semua dipertahankan)"}`);
for (const role of ROLES) console.log(`  ${role.padEnd(24)} ${vals[`${role}_ADDRESS`]}`);
console.log(`  DEPLOYER${" ".repeat(17)} ${vals.DEPLOYER_ADDRESS}`);
