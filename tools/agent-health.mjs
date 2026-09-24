// Cek apakah loop agen benar-benar masih bekerja.
//
// Kenapa ini ada di repo: loop sudah berhenti tiga kali dalam dua hari — sekali karena satu
// permintaan RPC gagal, sekali karena bug baca plafon harian, sekali dibunuh dari luar — dan
// setiap kali tidak ada yang menyadari, karena yang mati adalah proses, bukan kode. Repo tetap
// hijau, tes tetap lulus, dan riwayat aksi berhenti bertambah. Yang hilang tidak bisa dibeli
// kembali: aksi tanpa manusia yang justru jadi bahan demo.
//
// Dua pertanyaan yang dijawab, dan keduanya harus dijawab ya:
//   1. ada proses yang memegang lock dan masih hidup?
//   2. ledger bertambah baru-baru ini?
//
//   node tools/agent-health.mjs          (atau: npm run health)
// Keluar: 0 sehat, 1 tidak sehat -> bisa dipakai cron/CI untuk benar-benar berhenti galat.

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const LOCK = join(ROOT, "agent", "rune-agent.lock");
const HIST = join(ROOT, "agent", "history", "actions.jsonl");

// Tick default 360 detik; 4 tick tanpa catatan baru = jelas ada yang salah, bukan cuma jeda.
const TICK_SECONDS = Number(process.env.TICK_SECONDS ?? 360);
const STALE_AFTER_MIN = (4 * TICK_SECONDS) / 60;

function pidAlive(pid) {
  try {
    // signal 0 = tes keberadaan, tidak mengirim apa pun (definisi Node, bukan trik).
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err?.code === "EPERM"; // ada proses, kita cuma tidak boleh melihatnya
  }
}

let ok = true;
const reasons = [];

if (!existsSync(LOCK)) {
  ok = false;
  reasons.push("tidak ada agent/rune-agent.lock -> tidak ada loop yang seharusnya jalan");
} else {
  const pid = Number(readFileSync(LOCK, "utf8").trim());
  if (!Number.isInteger(pid) || pid <= 0) {
    ok = false;
    reasons.push(`isi lock bukan pid yang sah: ${JSON.stringify(readFileSync(LOCK, "utf8").trim())}`);
  } else if (!pidAlive(pid)) {
    ok = false;
    reasons.push(`lock menunjuk pid ${pid} yang sudah mati -> loop berhenti tanpa ada yang tahu`);
  } else {
    console.log(`proses agen hidup: pid ${pid}`);
  }
}

if (!existsSync(HIST)) {
  ok = false;
  reasons.push("belum ada agent/history/actions.jsonl -> agen belum pernah jalan");
} else {
  const recs = readFileSync(HIST, "utf8")
    .split(/\r?\n/)
    .filter(Boolean)
    .map((l) => {
      try {
        return JSON.parse(l);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
  const lastMs = Math.max(...recs.map((r) => r.t ?? 0));
  const ageMin = (Date.now() - lastMs) / 60_000;
  const done = recs.filter((r) => r.event === "resolve").length;
  const abst = recs.filter((r) => r.event === "abstain").length;
  const errs = recs.filter((r) => r.event === "error").length;

  console.log(`ledger: ${done} aksi tuntas · ${abst} abstain · ${errs} error · total ${recs.length} catatan`);
  console.log(`catatan terakhir: ${ageMin.toFixed(1)} menit lalu`);

  if (ageMin > STALE_AFTER_MIN) {
    ok = false;
    reasons.push(
      `tidak ada catatan ${ageMin.toFixed(0)} menit (ambang ${STALE_AFTER_MIN.toFixed(1)} menit = 4 tick) ` +
        "-> loop mungkin hidup tapi tidak menghasilkan apa pun; cek apakah semua agen abstain terus",
    );
  }
  // Abstain yang terus-menerus bukan selalu rusak, tapi selalu perlu dilihat: plafon harian
  // yang terbaca salah pernah membuat dunia diam berjam-jam dengan log yang meyakinkan.
  const tail = recs.slice(-6).filter((r) => r.event === "abstain");
  if (tail.length === 6) {
    console.log("  !! 6 catatan terakhir semuanya abstain:", tail[0].reason?.slice(0, 90));
  }
}

if (!ok) {
  console.log("\nTIDAK SEHAT:");
  for (const r of reasons) console.log("  -", r);
  console.log("\nmulai lagi:  node agent/rune-agent.mjs   (background task)");
  console.log("lock basi  :  hapus agent/rune-agent.lock kalau pid-nya memang sudah mati");
  process.exit(1);
}
console.log("\nSEHAT");
