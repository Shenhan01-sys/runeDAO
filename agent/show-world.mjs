// Tampilan dunia dari chain — TANPA transaksi.
//
// Dipakai dua hal sekaligus: (a) pra-terbang sebelum agen jalan, untuk melihat apa yang akan
// mereka putuskan tanpa membakar gas, dan (b) dasar halaman web nanti: semuanya dibaca dari
// contract yang sama, jadi apa yang dilihat di terminal dan di browser tidak bisa berbeda.
//
//   npm run world

import {
  ABI,
  FACTION_TAGS,
  decide,
  KIND_ENTRENCH,
  KIND_RAID,
  loadEnv,
  makeClient,
} from "./rune-agent.mjs";

const E = loadEnv();
const WORLD = E.WORLD_ADDRESS;
const REGISTRY = E.REGISTRY_ADDRESS;
const TREASURY = E.TREASURY_ADDRESS;
const { client } = makeClient(E);

const count = await client.readContract({ address: WORLD, abi: ABI, functionName: "REGION_COUNT" });
const cooldown = await client.readContract({ address: WORLD, abi: ABI, functionName: "regionCooldown" });
const now = Math.floor(Date.now() / 1000);

const regions = [];
for (let i = 0n; i < BigInt(count); i++) {
  const r = await client.readContract({ address: WORLD, abi: ABI, functionName: "getRegion", args: [i] });
  const threshold = await client.readContract({ address: WORLD, abi: ABI, functionName: "raidThreshold", args: [i] });
  regions.push({
    id: i,
    name: r[0],
    owner: r[1],
    strength: r[2],
    pool: r[3],
    lastActed: r[5],
    threshold,
    open: Number(r[5]) === 0 || Number(r[5]) + Number(cooldown) <= now,
  });
}

console.log(`\n=== DUNIA (cooldown ${cooldown}s) ===`);
for (const r of regions) {
  const owner = Number(r.owner) === 0 ? "netral" : `faksi ${r.owner}`;
  const pool = Number(r.pool) / 1e18;
  console.log(
    `  ${String(r.id).padStart(2)} ${r.name.padEnd(12)} ${owner.padEnd(9)} kuat ${String(r.strength).padStart(2)}  ambang ${String(r.threshold).padStart(2)}  pool ${pool.toFixed(4)}  ${r.open ? "TERBUKA" : "cooldown"}`
  );
}

console.log("\n=== AGEN DAN KEPUTUSANNYA (dihitung, tidak disiarkan) ===");
for (const tag of FACTION_TAGS) {
  const factionId = BigInt(FACTION_TAGS.indexOf(tag) + 1);
  const addr = E[`FACTION_${tag}_AGENT_ADDRESS`];
  const [operable, capRAID, capENTRENCH, a, tier, capPair, raidCost, entrenchCost, bnb, faction] = await Promise.all([
    client.readContract({ address: REGISTRY, abi: ABI, functionName: "isOperable", args: [addr] }),
    client.readContract({ address: REGISTRY, abi: ABI, functionName: "hasCapability", args: [addr, KIND_RAID] }),
    client.readContract({ address: REGISTRY, abi: ABI, functionName: "hasCapability", args: [addr, KIND_ENTRENCH] }),
    client.readContract({ address: REGISTRY, abi: ABI, functionName: "getAgent", args: [addr] }),
    client.readContract({ address: REGISTRY, abi: ABI, functionName: "tierOf", args: [addr] }),
    client.readContract({ address: TREASURY, abi: ABI, functionName: "effectiveCaps", args: [addr] }),
    client.readContract({ address: WORLD, abi: ABI, functionName: "RAID_COST" }),
    client.readContract({ address: WORLD, abi: ABI, functionName: "ENTRENCH_COST" }),
    client.getBalance({ address: addr }),
    client.readContract({ address: TREASURY, abi: ABI, functionName: "getFaction", args: [factionId] }),
  ]);

  const view = {
    agent: { operable, reputation: a[3], actions: a[4], failures: a[5] },
    faction: { balance: faction[1] },
    caps: { perAction: capPair[0], daily: capPair[1], raidCost, entrenchCost },
    gas: { bnb, needed: 740000n * 100000000n },
  };

  const d = decide({
    agent: view.agent,
    factionId,
    regions,
    faction: view.faction,
    caps: view.caps,
    gas: view.gas,
    capRAID,
    capENTRENCH,
  });

  console.log(`  agen-${tag} ${addr}`);
  console.log(
    `    reputasi ${a[3]} (tier ${tier})  aksi ${a[4]}  gagal ${a[5]}  operable ${operable}`
  );
  console.log(
    `    kas faksi ${(Number(faction[1]) / 1e18).toFixed(4)} BNB  plafon/aksi ${(Number(capPair[0]) / 1e18).toFixed(4)}  gas agen ${(Number(bnb) / 1e18).toFixed(4)}`
  );
  console.log(`    -> ${d.action}${d.regionId !== undefined ? ` region ${d.regionId}` : ""}: ${d.reason}`);
}

const actionsFile = new URL("./history/actions.jsonl", import.meta.url);
try {
  const { readFileSync } = await import("node:fs");
  const lines = readFileSync(actionsFile, "utf8").trim().split(/\r?\n/).filter(Boolean);
  const recs = lines.map((l) => JSON.parse(l));
  const done = recs.filter((r) => r.event === "resolve").length;
  const stuck = recs.filter((r) => r.event === "stuck").length;
  const errs = recs.filter((r) => r.event === "error").length;
  // `${resolves}` di sini dulu mencetak SELURUH isi array sebagai teks (satu barisan JSON
  // panjang ke terminal) karena lupa `.length` — dan itu juga menaruh semua secret di layar.
  console.log(`\n=== riwayat lokal: ${lines.length} catatan | ${done} aksi tuntas | ${errs} error | ${stuck} terkunci ===`);
  const outcomes = recs.filter((r) => r.event === "resolve").map((r) => r.outcome);
  if (outcomes.length) {
    const won = outcomes.filter((o) => o.success).length;
    console.log(`    dadu: ${won} berhasil / ${outcomes.length - won} gagal  (roll ${outcomes.map((o) => o.roll).join(", ")})`);
  }
} catch {
  console.log(`\n=== riwayat lokal belum ada (agen belum pernah jalan) ===`);
}
