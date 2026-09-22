# rune/node — agen otonom dengan kas yang dibatasi kontrak

Indonesia Web3 Hackathon 2026 · track **AI Agents** · target deploy **BSC testnet (chain 97)**.

Satu kalimat: **beberapa agen AI mengelola treasury on-chain milik sendiri dan mengambil
keputusan tanpa manusia, dan kontraklah — bukan janji kami — yang membatasi seberapa besar
mereka boleh salah.**

## Provenance (dibaca dulu, ini soal kelayakan)

Struktur permainannya berasal dari **RuneDAO**, entri saya sendiri untuk *0G Bridge Buildathon
by AKINDO* (kontraknya ditulis 23 Agustus 2026, lokal saja, tidak pernah dipublikasikan dan
tidak pernah di-deploy). Yang ada di repo ini **bukan port dan bukan salinan**:

| | versi 0G | di sini |
|---|---|---|
| Kontrak | 5 berkas, 869 baris, Hardhat + OZ `AccessControl` | ditulis ulang dari nol, Foundry, `Ownable` + guardian-split |
| Kas faksi | cek `msg.sender == agen` lalu lepas jumlah **berapa pun** — tanpa cap, tanpa daftar penerima, tanpa jeda | 4 gerbang: `perActionCap`, `dailyCap` (melacak **jumlah**), `minInterval`, `allowedTarget` |
| Bukti "AI" | field `aiProofHash` berisi `bytes32` bebas yang **tidak diverifikasi apa pun** | dihapus; yang dibuktikan hanya yang benar-benar bisa dibuktikan |
| Batas belanja | milik guardian, statis | **ikut reputasi agen**, dan reputasi itu digerakkan oleh hasil permainan |
| Runtime | `bot/` dan `shared/` **kosong**; satu-satunya UI adalah mock dengan hash acak | loop agen nyata yang menyiarkan transaksi sendiri |

Kode di repo ini ditulis selama periode hackathon, dengan riwayat commit yang bisa diperiksa
publik. Konsep permainan tidak kami klaim sebagai hal baru; **mekanisme penahan daya
belanjanya** yang baru.

## Kenapa bentuknya begini

Demo "agen AI pegang wallet sendiri" selalu mati di pertanyaan yang sama: *apa yang terjadi
kalau agen itu salah, tersesat, atau dibajak?* Jawaban berupa "kami matikan manual" bukan
jawaban — juri tidak bisa mengujinya.

Jadi yang dibangun adalah **rem yang bisa dibuktikan di chain**:

1. **Reputasi bergerak dua arah.** Hanya kontrak `world` yang boleh mengubahnya; guardian
   dan platform keduanya ditolak (`OnlyWorld`). Kegagalan menurunkan angka.
2. **Plafon mengikuti reputasi.** Agen yang gagal terus **memperkecil batas belanjanya
   sendiri**, on-chain, tanpa ada yang perlu mematikan prosesnya. Naiknya juga dibatasi
   (`MAX_TIER_BONUS = 3`) supaya agen senior tidak mendapat kas tak terbatas.
3. **Dua rem, dua pemilik.** Guardian bisa `suspend()` alatnya sendiri; platform bisa
   `delist()` izin main. Yang kedua tidak bisa dilepas oleh guardian, dan tidak menghapus
   riwayat aksi yang sudah tercatat.
4. **Daftar penerima kosong secara default.** Agen tidak bisa mengirim ke alamat karangan
   sendiri.

## Isi

```
contracts/RuneRegistry.sol   agen, kapabilitas, reputasi dua arah, dua rem
contracts/RuneTreasury.sol   kas faksi + 4 gerbang belanja + plafon berbasis reputasi
test/RuneRegistry.t.sol      26 test
test/RuneTreasury.t.sol      24 test
foundry.toml                 profil default (shanghai) + [profile.fork] (cancun)
```

`node_modules/` dan `lib/` di folder ini adalah **junction** ke milik `app/` — pola yang sama
dipakai `TradingAgent/` dan `AgenticTrack/`: satu resep dependensi (OZ 5.1.0, forge-std
1.16.2), nol kesempatan keduanya drifting.

## Menjalankan

```bash
forge build --deny warnings
forge test
```

Hasil terakhir di mesin ini: **50 passed, 0 failed** (24 + 26), Solc 0.8.26.

Dua jebakan yang sudah menggigit dan sekarang dikunci oleh tes, dicatat supaya tidak dibayar
dua kali:

- **`vm.prank()` termakan panggilan view.** Memakai `registry.STARTING_REPUTATION()` di dalam
  argumen setelah `vm.prank(world)` membuat prank habis di getter itu, dan pemanggil
  berikutnya datang dari alamat test. Ambil konstantanya ke variabel lokal **sebelum** prank.
- **OpenZeppelin 5 melempar custom error, bukan string.** `expectRevert("Ownable: caller is
  not the owner")` gagal; pakai `Ownable.OwnableUnauthorizedAccount.selector` dengan alamat
  pemanggil sebagai argumen.

## Yang TIDAK dibuktikan proyek ini

Ditulis di muka, karena itulah yang membuat klaim sisanya layak dipercaya:

- **Bahwa keputusan agen itu benar atau pintar.** Yang dibuktikan: siapa yang boleh
  bertindak, sejauh mana, dan apa akibatnya. Mutu keputusan agen tidak kami klaim dan tidak
  bisa kami klaim tanpa verifiable inference (TEE/zkML) — yang **tidak tersedia** sebagai
  lapisan first-party di chain ini.
- **Bahwa output LLM berasal dari model tertentu.** Kalau lapisan naratif memakai LLM, itu
  hiasan di atas keputusan yang dihitung off-chain; ia bukan bagian dari bukti.
- **Keaslian identitas agen di dunia nyata.** Yang terikat adalah address, bukan orang atau
  organisasi.
- **Ketepatan waktu`dailyCap` sampai detik.** `block.timestamp` bisa digeser penambang
  belasan detik; untuk jendela satu hari itu tidak berarti apa-apa, dan kami tidak akan
  mengklaim lebih.
