// Bangun web/index.html: satu berkas berdiri sendiri, data RANTAI di-inline ke dalamnya.
//
// Kenapa di-inline, bukan fetch saat halaman dibuka:
//  1. halaman harus bisa dibuka juri dengan dobel-klik (file://) — fetch ke berkas lokal
//     diblokir browser, dan fetch ke RPC publik dari browser bergantung CORS endpoint;
//  2. tidak ada server yang bisa mati di tengah demo, dan tidak ada state yang bisa kami
//     ubah diam-diam antara pembuatan halaman dan saat ia dibuka.
// Konsekuensinya jujur dan ditulis di halaman itu sendiri: ini SNAPSHOT pada blok X, bukan
// aliran langsung. Tombol refresh = jalankan ulang script ini.
//
//   node tools/build-page.mjs

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { createPublicClient, http, decodeEventLog, keccak256, parseAbi } from "viem";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const OUT = join(ROOT, "web", "index.html");
const RPC = process.env.RPC_URL || "https://bsc-testnet.publicnode.com";

const env = {};
for (const line of readFileSync(join(ROOT, ".env"), "utf8").split(/\r?\n/)) {
  const t = line.trim();
  if (t && !t.startsWith("#") && t.includes("=")) {
    const i = t.indexOf("=");
    env[t.slice(0, i).trim()] = t.slice(i + 1).trim();
  }
}

const WORLD = env.WORLD_ADDRESS;
const REGISTRY = env.REGISTRY_ADDRESS;
const TREASURY = env.TREASURY_ADDRESS;
if (!(WORLD && REGISTRY && TREASURY)) throw new Error(".env tidak lengkap");

const ABI_STR = [
  "function REGION_COUNT() view returns (uint96)",
  "function regionCooldown() view returns (uint32)",
  "function RAID_COST() view returns (uint96)",
  "function ENTRENCH_COST() view returns (uint96)",
  "function getRegion(uint96) view returns ((string, uint96, uint32, uint96, address, uint64, bool))",
  "function raidThreshold(uint96) view returns (uint8)",
  "function getAgent(address) view returns ((address, uint96, string, uint24, uint32, uint32, bool, bool, bool))",
  "function tierOf(address) view returns (uint256)",
  "function isOperable(address) view returns (bool)",
  "function getFaction(uint96) view returns ((address, uint96, uint96, uint96, uint32, uint64, uint96, uint64, uint96, uint32, bool, bool))",
  "function effectiveCaps(address) view returns (uint96, uint96)",
  "function actionCount() view returns (uint256)",
  "function raidsWon() view returns (uint256)",
  "function raidsFailed() view returns (uint256)",
  "event Action(bytes32 indexed actionId, address indexed agent, uint96 indexed regionId, bytes32 kind, uint8 roll, uint8 threshold, bool success, uint96 cost, uint32 strength, uint96 owner, bytes32 transcriptHash)",
];

// `parseAbi` wajib: meneruskan string human-readable langsung ke viem memberi
// `Cannot use 'in' operator to search for 'name' in function REGION_COUNT()...`.
const ABI = parseAbi(ABI_STR);
const ACTION_ABI = parseAbi([ABI_STR[ABI_STR.length - 1]]);

const client = createPublicClient({ transport: http(RPC) });
const block = await client.getBlockNumber();

const count = await client.readContract({ address: WORLD, abi: ABI, functionName: "REGION_COUNT" });
const cooldown = await client.readContract({ address: WORLD, abi: ABI, functionName: "regionCooldown" });
const raidCost = await client.readContract({ address: WORLD, abi: ABI, functionName: "RAID_COST" });
const entrenchCost = await client.readContract({ address: WORLD, abi: ABI, functionName: "ENTRENCH_COST" });
const totals = {
  actions: await client.readContract({ address: WORLD, abi: ABI, functionName: "actionCount" }),
  won: await client.readContract({ address: WORLD, abi: ABI, functionName: "raidsWon" }),
  failed: await client.readContract({ address: WORLD, abi: ABI, functionName: "raidsFailed" }),
};

const KIND_RAID = keccak256(new TextEncoder().encode("RAID"));
const KIND_ENTRENCH = keccak256(new TextEncoder().encode("ENTRENCH"));

const regions = [];
for (let i = 0n; i < BigInt(count); i++) {
  const [r, th] = await Promise.all([
    client.readContract({ address: WORLD, abi: ABI, functionName: "getRegion", args: [i] }),
    client.readContract({ address: WORLD, abi: ABI, functionName: "raidThreshold", args: [i] }),
  ]);
  regions.push({
    id: Number(i),
    name: r[0],
    owner: Number(r[1]),
    strength: r[2],
    pool: r[3].toString(),
    lastDefender: r[4],
    lastActed: Number(r[5]),
    threshold: th,
  });
}

const agents = [];
for (const tag of ["A", "B", "C"]) {
  const addr = env[`FACTION_${tag}_AGENT_ADDRESS`];
  const guardian = env[`FACTION_${tag}_GUARDIAN_ADDRESS`];
  const factionId = ["A", "B", "C"].indexOf(tag) + 1;
  const [a, tier, operable, capPair, fac] = await Promise.all([
    client.readContract({ address: REGISTRY, abi: ABI, functionName: "getAgent", args: [addr] }),
    client.readContract({ address: REGISTRY, abi: ABI, functionName: "tierOf", args: [addr] }),
    client.readContract({ address: REGISTRY, abi: ABI, functionName: "isOperable", args: [addr] }),
    client.readContract({ address: TREASURY, abi: ABI, functionName: "effectiveCaps", args: [addr] }),
    client.readContract({ address: TREASURY, abi: ABI, functionName: "getFaction", args: [BigInt(factionId)] }),
  ]);
  agents.push({
    tag,
    factionId,
    agent: addr,
    guardian,
    label: a[2],
    reputation: a[3],
    actions: a[4],
    failures: a[5],
    suspended: a[6],
    delisted: a[7],
    tier: Number(tier),
    operable,
    capPerAction: capPair[0].toString(),
    capDaily: capPair[1].toString(),
    balance: fac[1].toString(),
    spentToday: fac[6].toString(),
    spends: fac[9],
    frozen: fac[10],
  });
}

// Riwayat aksi: diambil dari log chain, bukan dari berkas lokal kita.
let logs = [];
try {
  logs = await client.getLogs({
    address: WORLD,
    events: ACTION_ABI,
    fromBlock: block > 20000n ? block - 20000n : 0n,
    toBlock: block,
  });
} catch (err) {
  console.log("getLogs gagal (banyak RPC publik membatasi rentang):", String(err?.message).slice(0, 80));
}

const actions = [];
for (const l of logs) {
  try {
    const d = decodeEventLog({ abi: ABI, data: l.data, topics: l.topics });
    if (d.eventName !== "Action") continue;
    actions.push({
      block: Number(l.blockNumber),
      tx: l.transactionHash,
      agent: d.args.agent,
      region: Number(d.args.regionId),
      kind: d.args.kind === KIND_RAID ? "RAID" : d.args.kind === KIND_ENTRENCH ? "ENTRENCH" : "lain",
      roll: Number(d.args.roll),
      threshold: Number(d.args.threshold),
      success: d.args.success,
      cost: d.args.cost.toString(),
      strength: Number(d.args.strength),
      owner: Number(d.args.owner),
      transcript: d.args.transcriptHash,
    });
  } catch {
    /* bukan event yang kita kenali */
  }
}
actions.reverse();

const data = {
  generatedAt: new Date().toISOString(),
  chainId: 97,
  block: Number(block),
  contracts: { registry: REGISTRY, treasury: TREASURY, world: WORLD },
  rules: {
    cooldown: Number(cooldown),
    raidCost: raidCost.toString(),
    entrenchCost: entrenchCost.toString(),
  },
  totals: { actions: Number(totals.actions), won: Number(totals.won), failed: Number(totals.failed) },
  regions,
  agents,
  actions,
};

const html = await render(data);
writeFileSync(OUT, html, "utf8");
console.log(`web/index.html ditulis: ${actions.length} aksi, ${regions.length} wilayah, blok ${data.block}`);

async function render(d) {
  const payload = JSON.stringify(d).replace(/</g, "\\u003c");
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>runeDAO on BNB Chain — live world</title>
<style>
:root{--bg:#0d1117;--fg:#e6edf3;--dim:#8b949e;--line:#30363d;--win:#238636;--lose:#da3633;--gold:#bb8009}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 ui-sans-serif,system-ui,"Segoe UI",Roboto,sans-serif}
main{max-width:1080px;margin:0 auto;padding:28px 20px 64px}
h1{font-size:22px;margin:0 0 4px}h2{font-size:15px;margin:34px 0 10px;color:var(--dim);text-transform:uppercase;letter-spacing:.08em}
.sub{color:var(--dim);font-size:13px}
code{background:#161b22;padding:1px 5px;border-radius:4px;font-size:12.5px}
a{color:#58a6ff}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:10px}
.card{border:1px solid var(--line);border-radius:8px;padding:12px}
.row{display:flex;justify-content:space-between;gap:10px;font-size:13.5px}
.bar{height:6px;background:#21262d;border-radius:3px;margin-top:7px;overflow:hidden}
.bar i{display:block;height:100%;background:var(--win)}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);white-space:nowrap}
th{color:var(--dim);font-weight:600}
td.num{text-align:right;font-variant-numeric:tabular-nums}
.win{color:var(--win)}.lose{color:var(--lose)}
.own1{color:#58a6ff}.own2{color:#d2a8ff}.own3{color:#ffa657}.neutral{color:var(--dim)}
.note{border-left:3px solid var(--gold);background:#161b22;padding:12px 14px;border-radius:0 6px 6px 0;margin-top:10px}
.note ul{margin:8px 0 0;padding-left:20px}
.scroll{overflow-x:auto}
</style></head><body><main>
<h1>runeDAO on BNB Chain</h1>
<p class="sub">Autonomous agents with faction treasuries where <b>the contract</b>, not the promise,
bounds how wrong they can be. BNB Smart Chain testnet (chainId 97) · track AI Agents.</p>
<p class="sub" id="stamp"></p>
<h2 id="hworld">World</h2><div class="grid" id="regions"></div>
<h2>Agents, reputation and the budget it buys</h2>
<div class="scroll"><table id="agents"></table></div>
<h2>Actions taken by the agents themselves</h2>
<div class="scroll"><table id="log"></table></div>
<h2>What this page does not prove</h2>
<div class="note"><ul id="limits"></ul></div>
<h2>Contracts</h2><p class="sub" id="contracts"></p>
</main>
<script>
const D = ${payload};
const EXPLORER = "https://testnet.bscscan.com";
const bnb = (wei) => (Number(BigInt(wei)) / 1e18).toFixed(4).replace(/0+$/,"").replace(/\\.$/,"") + " BNB";
const short = (a) => a ? a.slice(0,6) + "…" + a.slice(-4) : "—";
const ownerName = (id) => id === 0 ? '<span class="neutral">unclaimed</span>' :
  '<span class="own' + id + '">faction ' + id + "</span>";
const txLink = (h) => '<a href="' + EXPLORER + "/tx/" + h + '" target="_blank" rel="noreferrer">' + short(h) + "</a>";
const addrLink = (a) => '<a href="' + EXPLORER + "/address/" + a + '" target="_blank" rel="noreferrer">' + short(a) + "</a>";

document.getElementById("stamp").innerHTML =
  "Snapshot read from chain at block <b>" + D.block + "</b> · generated " + D.generatedAt.replace("T"," ").slice(0,19) + " UTC"
  + " · <b>" + D.actions.length + "</b> agent actions in the log window (chain reports <b>" + D.totals.actions + "</b> total)"
  + " · static file: re-run <code>node tools/build-page.mjs</code> to refresh.";

document.getElementById("regions").innerHTML = D.regions.map(r => {
  const pct = Math.round(r.strength / 40 * 100);
  const last = r.lastActed ? new Date(r.lastActed * 1000).toISOString().slice(5,16).replace("T"," ") + "Z" : "never";
  return '<div class="card"><div class="row"><b>' + r.name + '</b><span>#' + r.id + '</span></div>'
    + '<div class="row"><span class="sub">holder</span><span>' + ownerName(r.owner) + '</span></div>'
    + '<div class="row"><span class="sub">strength / raid threshold</span><span>' + r.strength + ' / ' + r.threshold + '</span></div>'
    + '<div class="bar"><i style="width:' + pct + '%"></i></div>'
    + '<div class="row"><span class="sub">bounty from failed raids</span><span>' + bnb(r.pool) + '</span></div>'
    + '<div class="row"><span class="sub">last acted</span><span class="sub">' + last + '</span></div></div>';
}).join("");

const cols = ["faction","agent","guardian","reputation","tier","per-action cap","daily cap","spent today","treasury","actions","failed","status"];
document.getElementById("agents").innerHTML = "<tr>" + cols.map(c=>"<th>"+c+"</th>").join("") + "</tr>"
  + D.agents.map(a => "<tr>"
    + "<td>" + a.factionId + " · " + a.label + "</td>"
    + "<td>" + addrLink(a.agent) + "</td><td>" + addrLink(a.guardian) + "</td>"
    + '<td class="num">' + a.reputation + "</td>"
    + '<td class="num">' + a.tier + "</td>"
    + "<td>" + bnb(a.capPerAction) + "</td><td>" + bnb(a.capDaily) + "</td><td>" + bnb(a.spentToday) + "</td>"
    + "<td>" + bnb(a.balance) + "</td>"
    + '<td class="num">' + a.actions + "</td><td class='num lose'>" + a.failures + "</td>"
    + "<td>" + (a.delisted ? '<span class="lose">delisted by venue</span>'
        : a.suspended ? '<span class="lose">suspended by guardian</span>'
        : a.frozen ? '<span class="lose">treasury frozen</span>' : '<span class="win">active</span>') + "</td></tr>").join("");

document.getElementById("log").innerHTML = "<tr><th>block</th><th>tx</th><th>agent</th><th>region</th><th>action</th><th>roll</th><th>vs threshold</th><th>result</th><th>cost</th><th>after</th></tr>"
  + (D.actions.length ? D.actions.map(a => {
      const ag = D.agents.find(x => x.agent.toLowerCase() === a.agent.toLowerCase());
      return "<tr><td class=num>" + a.block + "</td><td>" + txLink(a.tx) + "</td>"
        + "<td>" + (ag ? "faction " + ag.factionId : short(a.agent)) + "</td>"
        + "<td>" + a.region + "</td><td>" + a.kind + "</td>"
        + '<td class="num">' + a.roll + "</td>"
        + "<td class=num>" + (a.kind === "RAID" ? a.threshold : "—") + "</td>"
        + '<td class="' + (a.success ? "win" : "lose") + '">' + (a.success ? "won" : "lost") + "</td>"
        + "<td>" + bnb(a.cost) + "</td>"
        + "<td>strength " + a.strength + ", holder " + (a.owner || "—") + "</td></tr>";
    }).join("") : '<tr><td colspan=10 class="sub">no Action events in the log window this RPC allowed</td></tr>');

document.getElementById("limits").innerHTML = [
  "The dice are <b>not provably fair</b>. A commitment is made against a block that does not exist yet, so the agent cannot pick its own outcome — but whoever mines that block retains some influence over its hash. Enough for a game; not enough for real stakes.",
  "<b>No language model is in the decision path.</b> Actions come from a deterministic policy that reads chain state. Nothing here proves model provenance or decision quality.",
  "What is proven is <em>authority and consequence</em>: who may make an agent act, what it may spend, what it cost, and what happened to its permissions afterwards.",
  "Faction identities are addresses. They correspond to no verified person or organisation.",
  "Money is testnet BNB with no value. The ceilings shown are enforced by the contract, not by this page — the page only reports them.",
  "This is a <b>static snapshot</b>, not a live feed: it cannot change after generation, which is the point. Refreshing means re-running the build script.",
].map(t => "<li>" + t + "</li>").join("");

document.getElementById("contracts").innerHTML =
  "world " + addrLink(D.contracts.world) + " · registry " + addrLink(D.contracts.registry)
  + " · treasury " + addrLink(D.contracts.treasury)
  + " · raid cost " + bnb(D.rules.raidCost) + " · entrench cost " + bnb(D.rules.entrenchCost)
  + " · region cooldown " + D.rules.cooldown + "s"
  + "<br>Read back directly: <code>npm run readback</code> · <code>npm run world</code> · source: <a href='https://github.com/Shenhan01-sys/runeDAO'>github.com/Shenhan01-sys/runeDAO</a>";
</script></body></html>`;
}
