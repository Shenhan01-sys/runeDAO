// Tes kebijakan `decide()` — fungsi yang memutuskan aksi agen di dunia nyata.
//
// Kenapa perlu: runner punya 89 tes Solidity yang tidak satu pun menyentuh fungsi ini, dan
// justru di sinilah dua bug lapangan berasal - (1) ENTRENCH tidak pernah terpilih sama sekali
// sepanjang 20 aksi pertama, (2) agen menyerang target yang expected-value-nya negatif karena
// "skor" yang saya inventariskan bukan EV. Dua-duanya tidak bisa ditangkap tes kontrak karena
// kontraknya berperilaku benar; yang salah adalah yang membacanya.
//
//   node tools/test-policy.mjs        (exit 1 kalau ada yang gagal)

import { HOLD_VALUE, decide, raidEV, winProb } from "../agent/rune-agent.mjs";

const RAID_COST = 300000000000000n; // 0.0003 BNB, dari kontrak
const ENTRENCH_COST = 100000000000000n;

let pass = 0;
const fails = [];

function t(name, fn) {
  try {
    fn();
    pass += 1;
  } catch (e) {
    fails.push(`${name}: ${e.message}`);
  }
}
function eq(a, b, msg = "") {
  if (a !== b) throw new Error(`dapat ${JSON.stringify(a)}, harus ${JSON.stringify(b)} ${msg}`);
}

const caps = { perAction: 800000000000000n, daily: 3200000000000000n, raidCost: RAID_COST, entrenchCost: ENTRENCH_COST };
const healthy = { operable: true, reputation: 500 };
const faction = { balance: 3000000000000000n, spentToday: 0n, spends: 0n };
const gas = { bnb: 1000000000000000n, needed: 740000n * 100000000n };

const region = (over) => ({ id: 0n, name: "R", owner: 0n, strength: 20, pool: 0n, threshold: 11, open: true, ...over });

t("winProb: angka kontrak, bukan kira-kira", () => {
  eq(winProb({ threshold: 11 }), 0.5, "ambang 11 = kepala dua");
  eq(winProb({ threshold: 4 }), 0.85, "ambang terendah yang dijepit kontrak");
  eq(winProb({ threshold: 19 }), 0.1, "ambang tertinggi yang dijepit kontrak");
});

t("raid +EV dipilih, dan yang terbesar", () => {
  const d = decide({
    agent: healthy,
    factionId: 1n,
    regions: [region({ id: 1n, threshold: 12, pool: 300000000000000n }), region({ id: 2n, threshold: 5, pool: 900000000000000n })],
    faction,
    caps,
    gas,
    capRAID: true,
    capENTRENCH: true,
  });
  eq(d.action, "RAID");
  eq(d.regionId, 2n, "hadiah besar + ambang rendah harus menang atas yang kecil");
  if (!/EV \+\d+/.test(d.reason)) throw new Error(`alasan harus menyebut EV: ${d.reason}`);
});

t("target -EV TIDAK diserang (regresi bug 'skor negatif')", () => {
  // ambang 12, hadiah 0: P=0.45, EV = -0.0003 -> dulu ini tetap diserang
  const d = decide({
    agent: healthy,
    factionId: 1n,
    regions: [region({ id: 4n, threshold: 12, pool: 0n })],
    faction,
    caps,
    gas,
    capRAID: true,
    capENTRENCH: true,
  });
  eq(d.action, "ABSTAIN", d.reason);
  if (!/EV -/.test(d.reason)) throw new Error(`alasan harus menyebut EV negatif yang jadi dasar tolak: ${d.reason}`);
});

t("wilayah sendiri yang lemah dipertahankan (regresi 0% ENTRENCH)", () => {
  const d = decide({
    agent: healthy,
    factionId: 1n,
    regions: [region({ id: 0n, owner: 1n, strength: 1, threshold: 4 }), region({ id: 4n, threshold: 19, pool: 0n })],
    faction,
    caps,
    gas,
    capRAID: true,
    capENTRENCH: true,
  });
  eq(d.action, "ENTRENCH");
  eq(d.regionId, 0n);
});

t("plafon harian yang menipis menahan aksi SEBELUM commit", () => {
  const d = decide({
    agent: healthy,
    factionId: 1n,
    regions: [region({ id: 2n, threshold: 4, pool: 900000000000000n })],
    faction: { ...faction, spentToday: 3100000000000000n },
    caps,
    gas,
    capRAID: true,
    capENTRENCH: true,
  });
  eq(d.action, "ABSTAIN", d.reason);
  if (!/plafon harian/.test(d.reason)) throw new Error("alasan harus menyebut plafon harian");
});

t("kas faksi kosong -> berhenti, bukan coba lalu revert", () => {
  const d = decide({
    agent: healthy,
    factionId: 1n,
    regions: [region({ id: 2n, threshold: 4, pool: 900000000000000n })],
    faction: { ...faction, balance: 0n },
    caps,
    gas,
    capRAID: true,
    capENTRENCH: true,
  });
  eq(d.action, "ABSTAIN", d.reason);
});

t("gas tidak cukup -> berhenti dengan angka", () => {
  const d = decide({
    agent: healthy,
    factionId: 1n,
    regions: [region({ id: 2n, threshold: 4, pool: 900000000000000n })],
    faction,
    caps,
    gas: { bnb: 1000n, needed: 74000000000000n },
    capRAID: true,
    capENTRENCH: true,
  });
  eq(d.action, "ABSTAIN", d.reason);
});

t("agen tidak operable (suspended/delisted) -> tidak bertindak", () => {
  const d = decide({
    agent: { ...healthy, operable: false },
    factionId: 1n,
    regions: [region({ id: 2n, threshold: 4, pool: 900000000000000n })],
    faction,
    caps,
    gas,
    capRAID: true,
    capENTRENCH: true,
  });
  eq(d.action, "ABSTAIN", d.reason);
});

t("HOLD_VALUE sendirian tidak membuat fortress layak diserang", () => {
  // ambang 19 -> P=0,10: 0,10 x 0,0005 = 0,00005 < biaya 0,0003
  eq(raidEV(region({ threshold: 19, pool: 0n }), caps) < 0n, true);
  eq(raidEV(region({ threshold: 16, pool: 0n }), caps) < 0n, true);
});

t("wilayah kosong tapi LEMAH layak diserang - ini yang membuat dunia hidup", () => {
  // ambang 4 -> P=0,85: 0,85 x 0,0005 = 0,000425 > 0,0003
  const d = decide({
    agent: healthy,
    factionId: 1n,
    regions: [region({ id: 5n, threshold: 4, pool: 0n })],
    faction,
    caps,
    gas,
    capRAID: true,
    capENTRENCH: true,
  });
  eq(d.action, "RAID", d.reason);
  if (!/nilai pegang/.test(d.reason)) throw new Error(`alasan harus menyebut nilai pegang wilayah: ${d.reason}`);
});

t("kebijakan menilai tempat beruang, bukan tempat termudah", () => {
  // Dulu skor terbalik: ambang rendah = skor tinggi, sampai 35 dari 38 raid EV-nya <= 0.
  const fortress = { pool: 3000000000000000n, threshold: 6 };
  const easyEmpty = { pool: 0n, threshold: 19 };
  const a = raidEV({ ...region(fortress), ...fortress }, caps);
  const b = raidEV({ ...region(easyEmpty), ...easyEmpty }, caps);
  if (!(a > 0n && b < 0n)) throw new Error(`hadiah besar/ambang tinggi harus mengalahkan wilayah kosong yang mudah: ${a} vs ${b}`);
});

// laporan
console.log(`${pass} lolos, ${fails.length} gagal`);
for (const f of fails) console.log("  GAGAL " + f);
process.exit(fails.length ? 1 : 0);
