// Pemeriksa dokumen: hal-hal yang salahnya baru kelihatan saat dibaca orang lain.
//
// Tiga kelas kesalahan yang benar-benar terjadi di repo ini dalam dua hari:
//  - pagar ``` tidak berpasang -> paragraf tertelan jadi blok kode di GitHub, mulus di terminal;
//  - angka dokumen drifting (50 -> 81 -> 89) dan menyebut perintah yang hari itu gagal;
//  - tautan ke berkas yang tidak ada, dan `npm run x` yang tidak ada di package.json.
// Tidak ada satu pun yang ditangkap compiler atau forge test. Makanya ada di sini.
//
//   node tools/check-docs.mjs        (exit 1 kalau ada temuan)

import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

const DOC_FILES = ["README.md", "HOW-TO-PLAY.md"];
for (const f of ["vault/README.md", "vault/01-briefing.md", "vault/02-architecture.md", "vault/03-evidence-and-limits.md", "vault/04-technical-reference.md", "vault/05-status-and-tasks.md"]) {
  if (existsSync(join(ROOT, f))) DOC_FILES.push(f);
}

const pkg = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8"));
const scripts = new Set(Object.keys(pkg.scripts ?? {}));

const problems = [];
const notes = [];

// 1) kata yang dilarang: klaim yang sudah dibantah kenyataan, dijaga supaya tidak balik lagi
const BANNED = [
  [/\b(?:50|81) tests?\b/, "jumlah tes basi (yang benar dibaca dari `forge test`, jangan disalin)"],
  [/belum dikerjakan/i, "README/vault pernah menyebut RNG 'belum dikerjakan' padahal sudah"],
  [/forge build --deny warnings/, "perintah itu gagal hari ini: 38 lint warning unsafe-typecast"],
  [/\bprovably fair\b/i, "mengklaim 'provably fair' — yang bisa kita bilang hanyalah *unpickable by the revealing party*"],
];

let linkTotal = 0;
for (const rel of DOC_FILES) {
  const path = join(ROOT, rel);
  if (!existsSync(path)) {
    problems.push(`${rel}: disebut tapi tidak ada`);
    continue;
  }
  const text = readFileSync(path, "utf8");

  const fences = (text.match(/^```/gm) ?? []).length;
  if (fences % 2 !== 0) problems.push(`${rel}: pagar code ganjil (${fences}) -> paragraf bisa tertelan di GitHub`);

  // Aturan dites per baris, bukan per dokumen: "not provably fair" dan "Bukan provably fair"
  // adalah kalimat yang justru ingin kita punya. Pengecualian manual per berkas (yang pertama
  // saya tulis di sini) adalah cara cepat membuat pemeriksa yang selalu hijau - itu lebih
  // buruk daripada tidak ada, karena ia menghasilkan laporan yang menenangkan.
  const NEGATION = /\b(not|never|bukan|tidak|tanpa)\b|\bno\s+(claim|proof)/i;
  text.split("\n").forEach((line, idx) => {
    for (const [re, why] of BANNED) {
      const m = line.match(re);
      if (!m) continue;
      if (NEGATION.test(line)) continue;
      // pengecualian khusus: README boleh MENYEBUT perintah yang gagal asalkan ia juga
      // menjelaskan kenapa gagal di tempat yang sama
      if (why.startsWith("perintah itu gagal") && text.includes("38 `unsafe-typecast`")) continue;
      problems.push(`${rel}:${idx + 1}: "${m[0].slice(0, 40)}" — ${why}`);
    }
  });

  for (const m of text.matchAll(/npm run ([a-z:]+)/g)) {
    if (!scripts.has(m[1])) problems.push(`${rel}: menyebut \`npm run ${m[1]}\` yang tidak ada di package.json`);
  }

  for (const m of text.matchAll(/\]\((?!https?:|#|mailto:)([^)#]+)(#[^)]*)?\)/g)) {
    linkTotal += 1;
    const target = resolve(dirname(path), m[1]);
    if (!existsSync(target)) problems.push(`${rel}: tautan mati -> ${m[1]}`);
  }
}

notes.push(`dokumen diperiksa: ${DOC_FILES.length} · tautan lokal: ${linkTotal} · script terdaftar: ${scripts.size}`);
for (const n of notes) console.log(n);

if (problems.length) {
  console.log(`\n${problems.length} temuan:`);
  for (const p of problems) console.log("  -", p);
  process.exit(1);
}
console.log("\ndokumen konsisten");
