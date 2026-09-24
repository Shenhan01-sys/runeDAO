# How to play — for someone seeing this for the first time

(English below the short Indonesian version. Same rules, same numbers.)

## Versi Indonesia (90 detik)

**Ini game apa?**
Ada 6 wilayah. Empat sudah dipegang oleh 3 program komputer yang berjalan sendiri —
mereka menyerang, mempertahankan diri, dan bayar sendiri untuk itu. Kamu bisa masuk sebagai
**pemilik faksi ke-4**: kamu tidak menggerakkan apa pun, kamu **mempersenjatai seorang agen dan
memasang batasnya**, lalu dia main sendiri.

**Yang bikin ini bukan sekadar bot yang kirim transaksi:** setiap keputusan agen itu meninggalkan
bekas yang bisa diperiksa publik, dan **uangmu punya plafon yang dijaga kontrak, bukan dijaga
janji kami.** Agen boleh salah. Dia tidak boleh boros.

**10 menit pertamamu:**

1. Lihat dulu, jangan pegang apa pun: buka `web/index.html`. Kamu akan lihat wilayah mana punya
   siapa, kekuatan tiap wilayah, dan tabel agen berisi **reputasi** dan **plafon belanja** mereka.
2. Baca satu aksi dari bawah ke atas. Klik salah satu link `tx` di tabel aksi. Kamu akan lihat:
   dadu yang keluar, ambangnya, menang atau kalah, dan berapa yang berpindah.
3. Sekarang buat faksimu sendiri (faksi 4). Isinya 4 perintah — lihat di bawah, "Langkah masuk".
4. Setor sedikit: 0.003 BNB testnet (uang testnet, nilainya nol).
5. Nyalakan agenmu dan **tutup laptopmu.** Itu bagian penting dari game ini: kamu tidak boleh
   perlu menyentuhnya lagi.
6. Besok, lihat kembali halamannya. Wilayahmu mungkin sudah direbut orang lain. Itu bukan
   kerusakan — itu game-nya.

**Kalimat kunci kalau kamu cuma ingat satu hal:** manusia memasang pagar; mesin yang main di
dalamnya.

## English version (the same 90 seconds)

**What is this?** Six regions. Four of them are already held by three programs that run themselves — they
attack, they defend, and they pay for it. You can join as the owner of a **fourth faction**: you
never move a piece, you **equip an agent and set its limits**, then it plays itself.

**What makes this more than a bot sending transactions:** every decision leaves a public trace, and
**your money has a ceiling enforced by the contract, not by our promise.** An agent is allowed to
be wrong. It is not allowed to be reckless.

---

## Langkah masuk (the four calls that are actually money)

You fund two wallets first: a **guardian** wallet (yours, the owner) and an **agent** wallet (the
thing that will act). Different keys, always — otherwise "the agent holds its own wallet" is a
slogan.

```text
1. buat faksi        treasury.createFaction(4)
2. pasang batas      treasury.setPolicy(4, 0.0005e18, 0.002e18, 60)
                     = max 0.0005 BNB per aksi, max 0.002 BNB per hari UTC, jeda min 60 detik
3. pilih penerima    treasury.setTarget(4, world, true)
                     daftar penerima dana kosong secara default — alamat lain ditolak
4. daftarkan agen    registry.registerAgent(4, agentAddr, "my-runner")
                     registry.setCapability(agentAddr, keccak256("RAID"), true)
5. setor             treasury.deposit{value: 0.003e18}(4)
```

Lalu agenmu bekerja sendiri:

```text
world.commit(hash, region, "RAID", blockNow + 6, transcriptHash)   ← niat, tanpa membocorkan hasil
... tunggu blok itu ditambang ...
world.resolve(secret)                                              ← dadu + akibatnya
```

Kenapa dua langkah dan bukan satu? Karena kalau hasilnya bisa diketahui sebelum kamu memutuskan,
kamu tidak sedang mengambil risiko — kamu sedang memilih-milih. Komitmenmu diikat ke **blok yang
belum ada**, jadi hasilnya belum bisa dihitung oleh siapa pun, termasuk kamu.

## Aturan main, satu layar

| | |
|---|---|
| **Wilayah** | 6 buah. Punya `kekuatan` 0–40. Makin tinggi kekuatan, makin rendah ambang penyerangnya. |
| **Menyerang (RAID)** | biaya 0.0003 BNB. Dadu d20 harus ≥ ambang. Menang: wilayah jadi milikmu + kamu ambil seluruh **hadiah (pool)** wilayah itu + reputasi naik. Kalah: uangmu tidak hilang — **masuk ke pool wilayah itu**, jadi hadiah bagi penyerang berikutnya + reputasi turun. |
| **Mengukuhkan (ENTRENCH)** | biaya 0.0001 BNB, hanya untuk wilayah yang sudah kamu pegang. Kekuatan naik sedikit. Ini bukan cara menang, ini cara tidak mudah direbut. |
| **Jeda** | 1 aksi per 5 menit per wilayah. Semua orang kena, termasuk kamu. |
| **Reputasi** | mulai 500, maks 1000. Naik saat menang, **turun saat kalah**. Ini satu-satunya angka yang mengubah seberapa besar agenmu boleh belanja. |
| **Plafon belanja** | batas yang kamu pasang × bonus reputasi (maks +60% di tier ≥ 3). Agen yang gagal terus mengecilkan plafonnya sendiri. Langit-langit keras yang tidak bisa kamu lewati: 0.01 per aksi, 0.05 per hari. |
| **Berhenti** | `suspend()` kamu matikan alatmu sendiri. `freeze()` kas faksimu dibekukan. `withdraw()` uangmu ditarik kembali — **tetap bisa walau faksi beku**, karena rem yang ikut mengunci dana pemiliknya itu sandera, bukan rem. |

Angka yang benar-benar terjadi sekarang, dari chain: agen C reputasinya **260** dengan plafon
**0.0007**; agen A reputasi **605** dengan plafon **0.0008**. Tidak ada yang memutuskan itu
manual — itu konsekuensi dari 8 kegagalannya, tercatat di chain, dan bisa dibaca ulang.

## "Kalau gitu tujuannya menang apa?"

Jujur: **tidak ada kondisi menang.** Tidak ada musim, tidak ada hadiah akhir, tidak ada skor
penutup. Yang ada hanyalah scoreboard: wilayah siapa, kas berapa, reputasi siapa naik/turun.

Itu pilihan, bukan kelalaian. Program ini bukan menjual "game yang seru"; ia menjual **bukti
bahwa mesin yang diizinkan memegang uang masih bisa dibuat bertanggung jawab.** Permainannya
adalah alat uji yang murah: satu-satunya lingkungan di mana agen boleh mengambil keputusan
berisiko nyata, salah, dan menanggung akibatnya — tanpa ada yang perlu kita percaya.

## Yang TIDAK game ini klaim

Ditulis di sini karena justru bagian ini yang bikin sisanya layak dipercaya:

- **Bukan provably fair.** Dadunya tidak bisa dipilih oleh yang mengungkap — tapi penambang blok
  acuan masih bisa menggeser hash bloknya sendiri sedikit. Cukup untuk game, tidak cukup untuk
  uang nyata.
- **Tidak ada AI di jalur keputusan.** Yang memutuskan aksi adalah fungsi deterministik yang
  membaca state chain. Tidak ada klaim tentang "kecerdasan" agen, dan tidak ada yang perlu
  membuktikan model mana yang menghasilkan sesuatu.
- **Bukan aset investasi.** Tidak ada token, tidak ada NFT, tidak ada marketplace, tidak ada
  penarikan keuntungan. Dananya testnet, nilainya nol.
- **Identitas agen bukan identitas manusia.** Yang terikat di chain adalah address.

## Kalau kamu cuma boleh melakukan satu hal

Jangan baca dokumen ini. Buka `web/index.html`, klik satu transaksi dari seorang agen, dan cocokkan
sendiri: niat → komitmen di chain → dadu → uang yang berpindah → reputasi yang berubah. Semua itu
terjadi tanpa ada yang mengetik perintah di menit itu, dan semuanya masih bisa kamu periksa
sekarang, bahkan kalau server kami besok hilang.
