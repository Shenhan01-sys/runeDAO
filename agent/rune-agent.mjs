// Runner agen RuneDAO di BNB Chain.
//
// Yang bikin ini bukan sekadar "script yang kirim transaksi":
//  - Keputusan aksi dibuat fungsi murni (`decide`), dan apa yang dipertimbangkannya ditulis ke
//    transcript SEBELUM hash-nya naik ke chain. Aksi tanpa catatan alasan ditolak kontrak
//    (`EmptyTranscript`), jadi itu bukan hiasan.
//  - Dadu memakai commit ke blok MASA DEPAN: agen tidak bisa tahu hasilnya saat berkomitmen,
//    jadi dia juga tidak bisa memilih-milih berdasarkan hasil yang belum terjadi.
//  - Agen berhenti sendiri ketika plafon atau gas tidak cukup, dan penolakannya dicatat.
//    `abstain` adalah hasil yang sah, bukan kegagalan yang disembunyikan.
//  - LLM tidak ada di jalur keputusan. Yang bisa dibuktikan di chain adalah aturan dan akibat,
//    bukan "otak" agen — dan kami tidak mengaku lebih.
//
// Aturan runtime yang sudah dibayar dengan kegagalan nyata, dan sekarang jadi kode:
//  a) Secret dicatat ke riwayat LOKAL pada saat COMMIT. Commit tanpa secret yang tersimpan =
//     agen rusak permanen, karena kontrak hanya menerima satu commit terbuka.
//  b) Setiap giliran dimulai dengan membuka commit yang menggantung. Crash di antara dua
//     transaksi tidak boleh jadi jalan buntu.
//  c) Nomor blok dari RPC publik bisa tertinggal dan kontrak menolak target yang sudah lewat
//     (TargetBlockNotFuture, terukur 23 Sep). Target dihitung ulang dan di-retry sekali.
//  d) viem TIDAK punya waitForBlockNumber. Kita poll getBlockNumber() sendiri.
//
//   npm run agent:once     satu putaran (tiga agen), lalu berhenti
//   npm run agent          terus-menerus sampai Ctrl+C

import { randomBytes } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  createPublicClient,
  createWalletClient,
  decodeEventLog,
  encodePacked,
  http,
  keccak256,
  parseAbi,
  toFunctionSelector,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const HISTORY_FILE = join(HERE, "history", "actions.jsonl");

export const FACTION_TAGS = ["A", "B", "C"];
const BLOCKS_AHEAD = 6;
// `blockhash()` hanya membaca 256 blok ke belakang; sisakan margin supaya keputusan
// "sudah tidak bisa dibuka" diambil sebelum benar-benar mentok.
const BLOCKHASH_READ_WINDOW = 250;
const TICK_SECONDS = Number(process.env.TICK_SECONDS ?? 420);
const GAS_PER_ACTION = 740000n;
// Ambang "cukup lemah untuk dipertahankan". 10 dipilih dari data: wilayah yang jatuh di
// bawah itu punya ambang raid <= 9 dan cenderung berpindah tangan tiap tick.
const DEFEND_BELOW = 10;
const WEI_PER_GAS = 100000000n; // 0,1 gwei — terukur dari eth_gasPrice chain 97, bukan asumsi

const bytes = (s) => new Uint8Array(Buffer.from(s, "utf8"));
export const KIND_RAID = keccak256(bytes("RAID"));
export const KIND_ENTRENCH = keccak256(bytes("ENTRENCH"));

/// ABI dibaca dari kontrak yang SUDAH dideploy. Kalau tanda tangannya tidak cocok dengan
/// chain, viem gagal keras — bukan salah kirim data diam-diam.
export const ABI = parseAbi([
  "function REGION_COUNT() view returns (uint96)",
  "function regionCooldown() view returns (uint32)",
  "function RAID_COST() view returns (uint96)",
  "function ENTRENCH_COST() view returns (uint96)",
  "function getRegion(uint96) view returns ((string, uint96, uint32, uint96, address, uint64, bool))",
  "function raidThreshold(uint96) view returns (uint8)",
  "function nonceOf(address) view returns (uint256)",
  "function getCommit(address) view returns ((bytes32, bytes32, uint32, uint96, bytes32, uint64, bool))",
  "function commit(bytes32,uint96,bytes32,uint32,bytes32)",
  "function resolve(bytes32)",
  "function abandon()",
  "function isOperable(address) view returns (bool)",
  "function hasCapability(address,bytes32) view returns (bool)",
  "function getAgent(address) view returns ((address, uint96, string, uint24, uint32, uint32, bool, bool, bool))",
  "function tierOf(address) view returns (uint256)",
  "function getFaction(uint96) view returns ((address, uint96, uint96, uint96, uint32, uint64, uint96, uint64, uint96, uint32, bool, bool))",
  "function effectiveCaps(address) view returns (uint96, uint96)",
  "event Action(bytes32 indexed actionId, address indexed agent, uint96 indexed regionId, bytes32 kind, uint8 roll, uint8 threshold, bool success, uint96 cost, uint32 strength, uint96 owner, bytes32 transcriptHash)",
]);

export function loadEnv(path = join(ROOT, ".env")) {
  const out = {};
  if (!existsSync(path)) return out;
  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    const t = line.trim();
    if (!t || t.startsWith("#") || !t.includes("=")) continue;
    const i = t.indexOf("=");
    out[t.slice(0, i).trim()] = t.slice(i + 1).trim();
  }
  return out;
}

// ------------------------------------------------------------------ keputusan

/**
 * Pilih aksi. Murni dan deterministik, supaya "kenapa agen ini melakukan itu" selalu bisa
 * dijawab dari state yang dibaca — bukan dari log yang ditulis setelah kejadian.
 *
 * Prioritasnya sendiri adalah kebijakan, dan ditulis di sini supaya bisa dibantah:
 *   1. pertahankan wilayah sendiri yang sudah lemah (< DEFEND_BELOW)
 *   2. raid ke wilayah dengan hadiah terbesar per unit risiko, asal ambangnya <= 15
 *   3. abstain, dengan alasan
 * Urutan 1-2 ini hasil ukut 20 aksi pertama dunia (lihat komentar di badan fungsi).
 * Gerbang biaya/plafon selalu di depan: aksi yang tidak bisa dibayar kas faksi bukan opsi.
 */
export function decide({ agent, factionId, regions, faction, caps, gas, capRAID, capENTRENCH }) {
  if (gas.bnb < gas.needed) {
    return { action: "ABSTAIN", reason: `gas ${gas.bnb} wei < ${gas.needed} yang dibutuhkan dua transaksi` };
  }
  if (!agent.operable) {
    return { action: "ABSTAIN", reason: "agen tidak operable (disuspensi guardian atau di-delist venue)" };
  }
  if (Number(faction.balance) === 0) {
    return { action: "ABSTAIN", reason: "kas faksi kosong" };
  }
  // Plafon HARIAN ditegakkan di `resolve()`, yaitu SETELAH commitment ada (temuan 23 Sep:
  // dua agen terkunci berjam-jam karena commit yang tak akan pernah bisa diselesaikan, dan
  // salah satunya mati tepat di gerbang ini). Maka headroom harian harus dihitung di sini —
  // bukan supaya kontraknya percaya, tapi supaya agen tidak membuang commitment yang sudah
  // pasti ditolak. `spentToday` dan `daily` dibaca dari chain, jadi ini prediksi, bukan izin.
  const dailyBudget = Number(caps.daily);
  if (dailyBudget > 0 && Number(faction.spentToday) + Number(caps.raidCost) > dailyBudget) {
    return {
      action: "ABSTAIN",
      reason: `plafon harian hampir habis: sudah ${faction.spentToday} dari ${dailyBudget} (aksi termurah ${caps.raidCost})`,
    };
  }

  const canRaid = capRAID && Number(faction.balance) >= Number(caps.raidCost) && Number(caps.perAction) >= Number(caps.raidCost);
  const canEntrench =
    capENTRENCH && Number(faction.balance) >= Number(caps.entrenchCost) && Number(caps.perAction) >= Number(caps.entrenchCost);

  const open = regions.filter((r) => r.open);
  const mine = open.filter((r) => Number(r.owner) === Number(factionId));
  const targets = open.filter((r) => Number(r.owner) !== Number(factionId));

  // DIPERBAIKI dari data lapangan, bukan dari kepala: 20 aksi pertama dunia ini 100% RAID dan
  // 0% ENTRENCH, karena cabang raid selalu bertemu target (ambang hanya bisa TURUN) sehingga
  // ENTRENCH tidak pernah tercapai — separuh aturan dunia tidak pernah diuji di chain.
  // Sekarang: wilayah sendiri yang sudah lemah dipertahankan lebih dulu. Ini juga menahan
  // umpan balik jahat yang terukur (Vhal'Mor: kekuatan 20 -> 0, ambang 11 -> 4, jadi pinata).
  if (canEntrench && mine.length) {
    const weak = mine.slice().sort((a, b) => Number(a.strength) - Number(b.strength))[0];
    if (Number(weak.strength) < DEFEND_BELOW) {
      return {
        action: "ENTRENCH",
        regionId: weak.id,
        cost: caps.entrenchCost,
        reason: `bertahan: wilayah sendiri tinggal ${weak.strength} (ambang ${weak.threshold}), diperebutkan terus`,
      };
    }
  }

  if (canRaid && targets.length) {
    const scored = targets
      .map((r) => ({
        r,
        // Hadiah per unit risiko. Ambang di atas 11 dihukum 4 poin per tingkat: angkanya
        // tertulis dan ikut masuk transcript, jadi keputusan bisa direplikasi orang lain.
        score: Number(r.pool) / Number(caps.raidCost) - (Number(r.threshold) - 11) * 4,
      }))
      .filter((x) => Number(x.r.threshold) <= 15)
      .sort((a, b) => b.score - a.score);

    if (scored.length) {
      const r = scored[0].r;
      return {
        action: "RAID",
        regionId: r.id,
        cost: caps.raidCost,
        reason: `pool ${r.pool}, ambang ${r.threshold}, kekuatan ${r.strength} — skor ${scored[0].score.toFixed(2)}`,
      };
    }
  }

  return {
    action: "ABSTAIN",
    reason: canRaid ? "tidak ada target dengan ambang <= 15" : "raid tidak lolos kas/plafon/kapabilitas",
  };
}

/**
 * Hash komitmen yang harus SAMA dengan hitungan kontrak:
 *   keccak256(abi.encodePacked(secret, targetBlock, msg.sender, nonce))
 * Concat string hex BUKAN pengganti encodePacked: targetBlock adalah 4 byte, bukan teks.
 */
export function commitHashOf({ secret, targetBlock, address, nonce }) {
  return keccak256(encodePacked(["bytes32", "uint32", "address", "uint256"], [secret, targetBlock, address, nonce]));
}

// ------------------------------------------------------------------ state chain

/// Index RPC dipilih eksplisit supaya loop bisa berpindah endpoint tanpa membangun ulang
/// daftar kandidat (dan tanpa kemungkinan dua klien menunjuk endpoint yang sama).
export function makeClient(E, index = 0) {
  const urls = [E.RPC_URL, E.RPC_URL_ALT, "https://bsc-testnet.publicnode.com", "https://bsc-testnet-rpc.publicnode.com"].filter(Boolean);
  const rpcUrl = urls[index % urls.length];
  return { client: createPublicClient({ transport: http(rpcUrl) }), rpcUrl, urls };
}

/** viem tidak punya waitForBlockNumber; nomor blok harus dibaca ulang, bukan dipercaya cache. */
async function waitUntilBlock(client, target) {
  for (let i = 0; i < 100; i++) {
    const n = await client.getBlockNumber();
    if (Number(n) >= target) return Number(n);
    await new Promise((r) => setTimeout(r, 700));
  }
  throw new Error(`blok ${target} tidak tercapai dalam ~70 detik`);
}

async function freshHead(client) {
  const b = await client.getBlock({ blockTag: "latest", includeTransactions: false });
  return Number(b.number);
}

async function readRegions(client, WORLD) {
  const count = await client.readContract({ address: WORLD, abi: ABI, functionName: "REGION_COUNT" });
  const cooldown = await client.readContract({ address: WORLD, abi: ABI, functionName: "regionCooldown" });
  const now = Math.floor(Date.now() / 1000);
  const out = [];
  for (let i = 0n; i < BigInt(count); i++) {
    const [r, threshold] = await Promise.all([
      client.readContract({ address: WORLD, abi: ABI, functionName: "getRegion", args: [i] }),
      client.readContract({ address: WORLD, abi: ABI, functionName: "raidThreshold", args: [i] }),
    ]);
    out.push({
      id: i,
      name: r[0],
      owner: r[1],
      strength: r[2],
      pool: r[3],
      lastDefender: r[4],
      lastActed: r[5],
      threshold,
      open: Number(r[5]) === 0 || Number(r[5]) + Number(cooldown) <= now,
    });
  }
  return { regions: out, cooldown: Number(cooldown) };
}

async function readAgentView(client, E, WORLD, REGISTRY, TREASURY, tag, factionId) {
  const account = privateKeyToAccount(E[`FACTION_${tag}_AGENT_PRIVATE_KEY`]);
  const addr = account.address;

  const [operable, capRAID, capENTRENCH, a, tier, capPair, raidCost, entrenchCost, bnb, nonce, pending] = await Promise.all([
    client.readContract({ address: REGISTRY, abi: ABI, functionName: "isOperable", args: [addr] }),
    client.readContract({ address: REGISTRY, abi: ABI, functionName: "hasCapability", args: [addr, KIND_RAID] }),
    client.readContract({ address: REGISTRY, abi: ABI, functionName: "hasCapability", args: [addr, KIND_ENTRENCH] }),
    client.readContract({ address: REGISTRY, abi: ABI, functionName: "getAgent", args: [addr] }),
    client.readContract({ address: REGISTRY, abi: ABI, functionName: "tierOf", args: [addr] }),
    // effectiveCaps mengembalikan TUPEL (uint96,uint96): viem membalasnya sebagai SATU array.
    client.readContract({ address: TREASURY, abi: ABI, functionName: "effectiveCaps", args: [addr] }),
    client.readContract({ address: WORLD, abi: ABI, functionName: "RAID_COST" }),
    client.readContract({ address: WORLD, abi: ABI, functionName: "ENTRENCH_COST" }),
    client.getBalance({ address: addr }),
    client.readContract({ address: WORLD, abi: ABI, functionName: "nonceOf", args: [addr] }),
    client.readContract({ address: WORLD, abi: ABI, functionName: "getCommit", args: [addr] }),
  ]);

  const faction = await client.readContract({ address: TREASURY, abi: ABI, functionName: "getFaction", args: [factionId] });

  // `spentToday` TIDAK bermakna tanpa `dayIndex`. Kontrak memperlakukannya sebagai "berlaku
  // hanya jika dayIndex == hari UTC sekarang"; membaca kolomnya telanjang membuat belanja
  // kemarin dihitung sebagai budget hari ini, dan agen berhenti selamanya - dengan log yang
  // terlihat persis seperti plafon sedang bekerja. Terjadi 24 Sep dan tidak tertangkap satu
  // pun dari 89 tes, karena setiap tes hidup di dalam satu hari yang sama.
  const utcDay = BigInt(Math.floor(Date.now() / 1000 / 86400));
  const spentToday = BigInt(faction[5]) === utcDay ? faction[6] : 0n;

  return {
    tag,
    account,
    factionId,
    capRAID,
    capENTRENCH,
    agent: { operable, reputation: a[3], actions: a[4], failures: a[5] },
    faction: { balance: faction[1], spentToday, spends: faction[9] },
    caps: { perAction: capPair[0], daily: capPair[1], raidCost, entrenchCost },
    tier,
    nonce,
    pending: pending[6]
      ? { hash: pending[0], transcriptHash: pending[1], targetBlock: Number(pending[2]), regionId: pending[3], kind: pending[4] }
      : null,
    gas: { bnb, needed: GAS_PER_ACTION * WEI_PER_GAS },
  };
}

// ------------------------------------------------------------------ transcript

function canonical(obj) {
  if (Array.isArray(obj)) return obj.map(canonical);
  if (obj && typeof obj === "object") {
    const out = {};
    for (const k of Object.keys(obj).sort()) out[k] = canonical(obj[k]);
    return out;
  }
  return obj;
}

function transcriptFor({ tag, factionId, decision, view, regions, targetBlock, head }) {
  // Yang di-hash dan yang ditulis ke file harus STRING yang sama persis, kalau tidak orang
  // lain tidak bisa mencocokkan transcript dengan hash yang ada di chain.
  const body = JSON.stringify(
    canonical({
      agent: tag,
      factionId: String(factionId),
      action: decision.action,
      regionId: decision.regionId === undefined ? null : String(decision.regionId),
      reason: decision.reason,
      considered: {
        reputation: String(view.agent.reputation),
        tier: String(view.tier),
        perActionCap: String(view.caps.perAction),
        factionBalance: String(view.faction.balance),
        gasWei: String(view.gas.bnb),
        regions: regions.map((r) => ({
          id: String(r.id),
          owner: String(r.owner),
          strength: r.strength,
          pool: String(r.pool),
          threshold: r.threshold,
          open: r.open,
        })),
      },
      headBlock: head,
      targetBlock,
      policyVersion: "decide-v1",
    })
  );
  return { json: body, hash: keccak256(bytes(body)) };
}

function log(obj) {
  mkdirSync(dirname(HISTORY_FILE), { recursive: true });
  appendFileSync(HISTORY_FILE, JSON.stringify(obj) + "\n");
}

function readLog() {
  if (!existsSync(HISTORY_FILE)) return [];
  return readFileSync(HISTORY_FILE, "utf8")
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
}

/// Secret ditemukan dari catatan commit lokal. Tanpa ini, crash di antara commit dan resolve
/// membuat agen tidak bisa dipakai lagi selamanya.
function secretForCommit(commitHash) {
  const want = String(commitHash).toLowerCase();
  for (const rec of readLog()) {
    if (rec.event === "commit" && rec.commitHash && String(rec.commitHash).toLowerCase() === want) return rec.secret;
  }
  return null;
}

const short = (h) => (h ? `${String(h).slice(0, 10)}…${String(h).slice(-6)}` : "");

/// Daftar error yang bisa dikeluarkan world/treasury, jadi selector dari receipt yang gagal
/// bisa dibaca manusia. Tanpa ini loop yang gagal hanya meninggalkan "status reverted" — dan
/// itu persis cara sistem otonom menjadi tidak bisa diaudit oleh pembuatnya sendiri.
const WORLD_ERRORS = [
  "NotOperable",
  "CapabilityMissing",
  "RegionUnknown",
  "RegionCooldownActive",
  "CommitAlreadyOpen",
  "EmptyTranscript",
  "TargetBlockNotFuture",
  "TargetBlockTooFar",
  "NoCommit",
  "CommitMismatch",
  "EmptySecret",
  "UnknownKind",
  "NotRegionOwner",
  "RevealWindowOpen",
];
const TREASURY_ERRORS = [
  "OnlyWorld",
  "EmptyProof",
  "GuardianMismatch",
  "FactionFrozenError",
  "TargetNotAllowed",
  "AbovePerActionCap",
  "AboveDailyCap",
  "TooSoon",
  "NotEnoughFunds",
  "UnknownFaction",
  "TransferFailed",
];

const ERROR_BY_SELECTOR = new Map([...WORLD_ERRORS, ...TREASURY_ERRORS].map((n) => [toFunctionSelector(`${n}()`), n]));

/// Ulangi panggilan yang gagal di blok sebelum ia ditambang, supaya alasan revert terbaca.
async function explainRevert(client, WORLD, txHash) {
  try {
    const [tx, receipt] = await Promise.all([
      client.getTransaction({ hash: txHash }),
      client.getTransactionReceipt({ hash: txHash }),
    ]);
    // Ulangi di blok SEBELUM tx itu ditambang: di situ state masih seperti saat kontrak
    // mengevaluasinya, jadi revert yang sama akan muncul lagi dan bisa didekode.
    await client.call({ to: tx.to, data: tx.data, account: tx.from, blockNumber: BigInt(receipt.blockNumber) - 1n });
    // "Lolos saat diulang" BUKAN penjelasan, dan dulu kalimatnya berpura-pura menjelaskan.
    // Sekarang ikut dilaporkan apa yang masih mungkin menjelaskan: apakah agen punya commit
    // menggantung (sebab paling mungkin: CommitAlreadyOpen), dan blok berapa tx itu mendarat.
    let pending = "tidak terbaca";
    try {
      const c = await client.readContract({
        address: WORLD,
        abi: ABI,
        functionName: "getCommit",
        args: [tx.from],
        blockNumber: BigInt(receipt.blockNumber) - 1n,
      });
      pending = c[6] ? `ADA (target ${c[2]}, region ${c[3]})` : "tidak ada";
    } catch {
      /* state historis mungkin tidak tersedia di RPC publik */
    }
    return (
      `re-estimasi di blok ${BigInt(receipt.blockNumber) - 1n} Justru lolos - jadi alasan revert bukan aturan yang bisa dilihat dari sana. ` +
      `Commit menggantung agen ini saat itu: ${pending}`
    );
  } catch (err) {
    const data = typeof err?.data === "string" ? err.data : err?.docsPath ? null : null;
    const sel = data && String(data).startsWith("0x") ? String(data).slice(0, 10) : null;
    const name = sel ? ERROR_BY_SELECTOR.get(sel) : null;
    if (name) return `${name} (${sel})`;
    const decoded = err?.shortMessage ? String(err.shortMessage).split("\n")[0] : null;
    return decoded ? `${decoded}${sel ? ` [${sel}${name ? ":" + name : ""}]` : ""}` : String(err?.message ?? err).slice(0, 120);
  }
}


// ------------------------------------------------------------------ transaksi

/// Hitung kegagalan per-agent dari riwayat, supaya "terkunci" tidak lagi diukur dari satu
/// event yang hanya muncul saat secret hilang — metrik lama melaporkan "0 terkunci" justru
/// ketika seorang agen gagal sembilan tick berturut-turut.
export function stuckReport() {
  const recs = readLog();
  const byTag = new Map();
  for (const r of recs) {
    if (!["error", "resolve", "abandon", "stuck"].includes(r.event)) continue;
    const cur = byTag.get(r.tag) ?? { streak: 0, worst: 0 };
    if (r.event === "resolve" || r.event === "abandon") {
      cur.streak = 0;
    } else {
      cur.streak += 1;
      cur.worst = Math.max(cur.worst, cur.streak);
    }
    byTag.set(r.tag, cur);
  }
  return [...byTag.entries()].map(([tag, v]) => ({ tag, ...v }));
}

function parseAction(receipt, WORLD) {
  for (const l of receipt.logs) {
    if (String(l.address).toLowerCase() !== String(WORLD).toLowerCase()) continue;
    try {
      const d = decodeEventLog({ abi: ABI, data: l.data, topics: l.topics });
      if (d.eventName === "Action") {
        return {
          actionId: d.args.actionId,
          kind: d.args.kind,
          roll: Number(d.args.roll),
          threshold: Number(d.args.threshold),
          success: d.args.success,
          cost: String(d.args.cost),
          strength: Number(d.args.strength),
          owner: String(d.args.owner),
          transcriptHash: d.args.transcriptHash,
        };
      }
    } catch {
      /* bukan event kita */
    }
  }
  return { roll: 0, threshold: 0, success: false, note: "event Action tidak ditemukan" };
}

async function resolveCommit({ client, wallet, WORLD, tag, secret, commitHash, targetBlock, transcriptHash, commitTx, regionId }) {
  await waitUntilBlock(client, targetBlock);
  const resolveTx = await wallet.writeContract({ address: WORLD, abi: ABI, functionName: "resolve", args: [secret] });
  const receipt = await client.waitForTransactionReceipt({ hash: resolveTx });
  if (receipt.status !== "success") {
    const why = await explainRevert(client, WORLD, resolveTx);
    throw new Error(`resolve ${short(resolveTx)} reverted: ${why}`);
  }
  const outcome = parseAction(receipt, WORLD);
  log({ t: Date.now(), tag, event: "resolve", tx: resolveTx, commitTx, commitHash, secret, targetBlock, transcriptHash, outcome });
  // Untuk raid yang berarti adalah roll vs ambang. Untuk entrench threshold SELALU 0 di
  // kontrak (tidak ada ambang), dan mencetak "vs ambang 0" membuat terminal demo terlihat
  // seperti hasilnya ditentukan oleh angka yang tidak ada. Yang berarti di sana: +kekuatan.
  const kindName = outcome.kind === KIND_ENTRENCH ? "ENTRENCH" : outcome.kind === KIND_RAID ? "RAID" : null;
  const verdict =
    kindName === "ENTRENCH"
      ? `dadu ${outcome.roll} -> kekuatan ${outcome.strength}${outcome.success ? "" : " (dadu kecil, tidak bertambah)"}`
      : `dadu ${outcome.roll} vs ambang ${outcome.threshold} -> ${outcome.success ? "BERHASIL" : "GAGAL"}`;
  console.log(`  [${tag}] ${verdict} ${short(resolveTx)}`);
  return { ...outcome, region: regionId };
}

/** Membuka commit yang tertinggal. Jalur pemulihan, bukan jalur normal. */
async function recoverPending({ client, wallet, WORLD, tag, view }) {
  const head = await freshHead(client);
  const secret = secretForCommit(view.pending.hash);

  // Jendela reveal lewat -> blockhash(targetBlock) tidak bisa dibaca lagi, jadi resolve
  // MEMANG tidak akan pernah berhasil. Versi pertama file ini tetap memanggil resolve di
  // keadaan itu dan kegagalan yang sama berulang setiap tick (terukur: agen C gagal 9x
  // berturut sejak 04:02 UTC) — kontrak sudah punya jalan keluar, runner-nya yang tidak
  // pernah memakai. abandon() membayarnya sebagai kegagalan reputasi dan agen lanjut hidup.
  if (head > view.pending.targetBlock + BLOCKHASH_READ_WINDOW) {
    console.log(
      `  [${tag}] commit ${short(view.pending.hash)} sudah di luar jendela reveal (blok ${head} > ${view.pending.targetBlock} + ${BLOCKHASH_READ_WINDOW}) -> abandon(), dibayar sebagai kegagalan`
    );
    const tx = await wallet.writeContract({ address: WORLD, abi: ABI, functionName: "abandon" });
    const rc = await client.waitForTransactionReceipt({ hash: tx });
    if (rc.status !== "success") throw new Error(`abandon ${short(tx)} reverted`);
    log({ t: Date.now(), tag, event: "abandon", tx, commitHash: view.pending.hash, targetBlock: view.pending.targetBlock });
    return { abandoned: true, region: view.pending.regionId };
  }

  if (!secret) {
    console.log(`  [${tag}] commit menggantung TANPA secret lokal (${short(view.pending.hash)}) — terkunci, perlu tangan manusia`);
    log({ t: Date.now(), tag, event: "stuck", commitHash: view.pending.hash, targetBlock: view.pending.targetBlock });
    return null;
  }
  console.log(`  [${tag}] memulihkan commit menggantung (target blok ${view.pending.targetBlock}, blok kini ${head})`);
  return resolveCommit({
    client,
    wallet,
    WORLD,
    tag,
    secret,
    commitHash: view.pending.hash,
    targetBlock: view.pending.targetBlock,
    transcriptHash: view.pending.transcriptHash,
    commitTx: null,
    regionId: view.pending.regionId,
  });
}

async function runTurn({ client, rpcUrl, WORLD, REGISTRY, TREASURY, E, tag, factionId, regions }) {
  const view = await readAgentView(client, E, WORLD, REGISTRY, TREASURY, tag, factionId);
  // Satu wallet per agen, dibuat dari akun agen itu sendiri: transaksi keluar dari kunci agen,
  // bukan dari kunci platform. Itu inti klaim "agen milik pihak ketiga".
  const wallet = createWalletClient({ account: view.account, transport: http(rpcUrl) });

  if (view.pending) {
    const back = await recoverPending({ client, wallet, WORLD, tag, view });
    return back ?? { blocked: true };
  }

  const decision = decide({
    agent: view.agent,
    factionId,
    regions,
    faction: view.faction,
    caps: view.caps,
    gas: view.gas,
    capRAID: view.capRAID,
    capENTRENCH: view.capENTRENCH,
  });

  if (decision.action === "ABSTAIN") {
    console.log(`  [${tag}] ABSTAIN — ${decision.reason}`);
    log({ t: Date.now(), tag, event: "abstain", reason: decision.reason, reputation: String(view.agent.reputation) });
    return { abstain: true };
  }

  const secret = `0x${randomBytes(32).toString("hex")}`;
  const kind = decision.action === "RAID" ? KIND_RAID : KIND_ENTRENCH;
  console.log(`  [${tag}] ${decision.action} region ${decision.regionId} — ${decision.reason}`);

  // Retry sekali dengan target dihitung ulang: RPC publik bisa tertinggal dan kontrak menolak
  // target yang sudah lewat.
  let lastErr = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const head = await freshHead(client);
      const targetBlock = head + BLOCKS_AHEAD;
      const nextNonce = BigInt(view.nonce) + 1n;
      const hash = commitHashOf({ secret, targetBlock, address: view.account.address, nonce: nextNonce });
      const tr = transcriptFor({ tag, factionId, decision, view, regions, targetBlock, head });

      const commitTx = await wallet.writeContract({
        address: WORLD,
        abi: ABI,
        functionName: "commit",
        args: [hash, decision.regionId, kind, targetBlock, tr.hash],
      });
      const commitReceipt = await client.waitForTransactionReceipt({ hash: commitTx });
      if (commitReceipt.status !== "success") {
        const why = await explainRevert(client, WORLD, commitTx);
        const e = new Error(`commit ${short(commitTx)} reverted: ${why}`);
        e.revertReason = why;
        throw e;
      }

      // Secret dicatat SEBELUM resolve: crash di tengah tidak boleh mengunci agen.
      log({
        t: Date.now(),
        tag,
        event: "commit",
        tx: commitTx,
        commitHash: hash,
        secret,
        targetBlock,
        regionId: String(decision.regionId),
        kind: decision.action,
        transcriptHash: tr.hash,
        transcript: JSON.parse(tr.json),
      });

      return await resolveCommit({
        client,
        wallet,
        WORLD,
        tag,
        secret,
        commitHash: hash,
        targetBlock,
        transcriptHash: tr.hash,
        commitTx,
        regionId: decision.regionId,
      });
    } catch (err) {
      lastErr = err;
      const msg = String(err?.shortMessage ?? err?.message ?? err);
      if (!msg.includes("TargetBlockNotFuture")) break; // hanya itu yang layak diulang
      console.log(`  [${tag}] target blok terlewat, hitung ulang (percobaan ${attempt + 2})`);
      await new Promise((r) => setTimeout(r, 1500));
    }
  }
  throw lastErr ?? new Error("commit gagal");
}

// ------------------------------------------------------------------ loop utama

export async function tick(deps) {
  const { client, rpcUrl, E, WORLD, REGISTRY, TREASURY } = deps;
  const { regions } = await readRegions(client, WORLD);
  const results = [];
  // Satu pembacaan state per tick = semua agen melihat dunia yang sama, dan tanpa reservasi
  // ini ketiganya memilih region yang sama persis (terukur: A, B, C semuanya menunjuk
  // region 0). Yang kedua dan ketiga akan revert RegionCooldownActive di chain. Region yang
  // sudah diambil ditandai tertutup untuk agen berikutnya — meniru apa yang ditegakkan
  // kontrak, bukan memperlonggarnya.
  const taken = new Set();
  for (const tag of FACTION_TAGS) {
    const factionId = BigInt(FACTION_TAGS.indexOf(tag) + 1);
    const seen = regions.map((r) => (taken.has(String(r.id)) ? { ...r, open: false } : r));
    try {
      const out = await runTurn({ client, rpcUrl, WORLD, REGISTRY, TREASURY, E, tag, factionId, regions: seen });
      if (out?.region !== undefined) taken.add(String(out.region));
      results.push(out);
    } catch (err) {
      const message = String(err?.shortMessage ?? err?.message ?? err).slice(0, 300);
      console.log(`  [${tag}] ERROR ${message}`);
      log({ t: Date.now(), tag, event: "error", message });
      results.push({ error: message });
    }
  }
  return results;
}

/// Satu loop per mesin. Dua proses dengan kunci agen yang sama saling mengganggu nonce, dan
/// itu tersangka paling mungkin untuk commit yang menggantung berjam-jam (terukur: target blok
/// 132.642.728 ditinggalkan ~7.100 blok, dan tabrakan loop terjadi setiap kali saya menyalakan
/// yang baru tanpa mematikan yang lama). Lock file + cek hidup proses, bukan ingatan operator.
const LOCK = join(HERE, "rune-agent.lock");

function otherInstanceAlive() {
  if (!existsSync(LOCK)) return null;
  try {
    const pid = Number(readFileSync(LOCK, "utf8").trim());
    if (!Number.isInteger(pid) || pid <= 0 || pid === process.pid) return null;
    process.kill(pid, 0); // tidak mengirim sinyal, hanya menguji apakah prosesnya ada
    return pid;
  } catch {
    return null; // lock basi (proses sudah mati) -> boleh diambil alih
  }
}

async function main() {
  const clash = otherInstanceAlive();
  if (clash) {
    console.error(`sudah ada instance rune-agent yang hidup (pid ${clash}) - berhenti, jangan dua loop`);
    console.error("kalau yakin itu proses yatim: hapus agent/rune-agent.lock lalu jalankan lagi");
    process.exit(1);
  }
  writeFileSync(LOCK, String(process.pid), { encoding: "utf8" });

  const E = loadEnv();
  const WORLD = E.WORLD_ADDRESS;
  const REGISTRY = E.REGISTRY_ADDRESS;
  const TREASURY = E.TREASURY_ADDRESS;
  if (!(WORLD && REGISTRY && TREASURY)) throw new Error(".env belum berisi REGISTRY/TREASURY/WORLD_ADDRESS");

  const { urls } = makeClient(E);
  let i = 0;
  let { client, rpcUrl } = makeClient(E, i);
  const once = process.argv.includes("--once");

  console.log(`runeDAO agent — world ${WORLD}`);
  console.log(`rpc ${rpcUrl}  tick ${TICK_SECONDS}s  sekali=${once}  pid ${process.pid}`);

  // Satu permintaan RPC yang gagal bukan alasan untuk berhenti. Terukur: loop ini mati pada
  // 06:28:36 UTC karena satu `fetch failed` pada eth_call REGION_COUNT() dan baru ketahuan
  // 3 jam 13 menit kemudian — waktu yang tidak bisa diambil kembali, karena riwayat aksi
  // tanpa-manusia justru bahan demo utamanya. Jadi: tangkap, catat, ganti endpoint, mundur
  // eksponensial, lanjut. Yang boleh mematikan proses hanya kesalahan konfigurasi.
  let misses = 0;
  for (;;) {
    const t0 = Date.now();
    try {
      await tick({ client, rpcUrl, E, WORLD, REGISTRY, TREASURY });
      if (misses > 0) console.log(`pulih setelah ${misses} tick gagal`);
      misses = 0;
    } catch (err) {
      misses += 1;
      const msg = String(err?.shortMessage ?? err?.message ?? err).split("\n")[0].slice(0, 160);
      console.log(`TICK GAGAL #${misses}: ${msg}`);
      log({ t: Date.now(), tag: "loop", event: "tick-error", message: msg, misses });
      if (/fetch failed|HTTP request failed|Timed out|520|408|socket hang up/i.test(msg)) {
        i = (i + 1) % urls.length;
        ({ client, rpcUrl } = makeClient(E, i));
        console.log(`  pindah rpc -> ${rpcUrl}`);
      }
    }
    if (once) break;
    const backoff = Math.min(600_000, 30_000 * 2 ** Math.min(misses, 4));
    const wait = misses > 0 ? backoff : Math.max(0, TICK_SECONDS * 1000 - (Date.now() - t0));
    await new Promise((r) => setTimeout(r, wait));
  }
}

if (process.argv[1]?.replace(/\\/g, "/").endsWith("agent/rune-agent.mjs")) {
  const release = () => {
    try {
      if (readFileSync(LOCK, "utf8").trim() === String(process.pid)) rmSync(LOCK, { force: true });
    } catch {
      /* lock sudah hilang, tidak perlu ribut saat keluar */
    }
  };
  process.on("exit", release);
  process.on("SIGINT", () => {
    release();
    process.exit(0);
  });
  main()
    .catch((e) => {
      console.error("FATAL", e);
      release();
      process.exit(1);
    });
}
