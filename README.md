# Nusva People · Backend (Phase 1 Domain Foundation)

Backend Supabase (Postgres + Auth + Row Level Security) untuk Nusva People Work
Management. Repo ini terpisah dari
[`nusvapeople-task`](https://github.com/ranggairawanp/nusvapeople-task), yang
tetap menjadi prototipe frontend statis sesuai CLAUDE.md di repo itu.

Dokumen desain lengkap (model tenant, otorisasi, ERD, keputusan D-1/D-2/D-3):
lihat dokumen "Nusva People — Phase 1 Domain Foundation" yang dibagikan terpisah.

## Project Supabase

- Nama: `nusva-people-backend`
- Region: Singapore (`ap-southeast-1`)
- Organisasi: Nusva AI

## Isi

```
supabase/migrations/   Migration SQL, urut sesuai penerapan ke database
```

| Migration | Isi |
| --- | --- |
| `001_tenant_and_org_hierarchy.sql` | Tenant → Organization → Legal Entity → Business Unit → Team → Position → Worker |
| `002_domain_core.sql` | Business Outcome, Priority, Driver, Commitment, Initiative, Work Item, Checklist |
| `003_dependency_evidence_audit.sql` | Dependency, Blocker, Evidence multi-tipe, Audit Log |
| `004_business_rule_triggers.sql` | State machine 7-tahap, pencegahan siklus Dependency, batas 2 Priority/tim dan 3 Driver/priority |
| `005_authorization_and_rls.sql` | Helper tenant/worker/role, Row Level Security di semua tabel |
| `006_harden_functions.sql` | Pin `search_path`, cabut akses anon ke fungsi helper |
| `007_harden_functions_v2.sql` | Cabut grant PUBLIC implisit, hanya `authenticated` yang boleh panggil helper |
| `008_bilingual_and_provenance_fields.sql` | Kolom dwibahasa (jsonb) untuk statement/title/hypothesis/unit/name, provenance pada Business Outcome |
| `009_seed_pt_abc_fb_company.sql` | Seed data PT ABC F&B Company diadopsi dari prototipe `data.js` (Decision D-3) |
| `010_work_item_actions_and_audit_trail.sql` | RPC `complete_work_item`/`raise_blocker`/`resolve_blocker`, policy tulis untuk checklist_items dan evidence, trigger audit_log generik |
| `011_harden_work_item_actions.sql` | Cabut akses anon ke tiga RPC di atas (linter keamanan) |
| `012_reanchor_due_dates_to_present.sql` | Geser `due_at` Work Item seed dari TODAY_ISO fiktif data.js ke tanggal nyata, supaya koneksi live ke frontend bisa didemokan |
| `013_seed_executive_and_hc_demo_accounts.sql` | Tambah 2 akun demo untuk role `executive` dan `hc_admin`, supaya keempat persona di frontend (karyawan, manajer, eksekutif, HC) punya akun untuk login setelah gerbang login pindah ke depan seluruh aplikasi |
| `014_create_work_item_rpc.sql` | RPC `create_work_item`, supaya tombol tambah pekerjaan (quick add) di Pekerjaan Saya/Board Tim bisa dipakai di mode nyata |
| `015_company_profile_and_worker_write_policies.sql` | Policy UPDATE untuk tenants/organizations/legal_entities/business_units, UPDATE+INSERT untuk teams/positions, dan UPDATE untuk workers, supaya profil perusahaan tidak lagi cuma bisa dibaca. Manager terbatas ke tim sendiri; tenant-wide dan perubahan role worker khusus executive/hc_admin |

Selain migration di atas, ada satu Edge Function (lihat bagian API di bawah):

```
supabase/functions/create_team_member/index.ts
```

Semua migration ini sudah diterapkan langsung ke project Supabase yang aktif
lewat MCP tool `apply_migration`. File di sini adalah salinan sumber kebenaran
untuk versioning, review, dan supaya bisa direplay ke environment lain
(staging, project baru) lewat Supabase CLI:

```
supabase link --project-ref qfvvijwieqcazmovowiq
supabase db push
```

## Status

- 21 tabel, RLS aktif di semuanya
- Linter keamanan Supabase bersih (satu peringatan yang disengaja: fungsi
  helper `current_tenant_id()`/`current_worker_id()`/`current_worker_role()`
  memang boleh dipanggil user login, karena cuma mengembalikan data milik
  pemanggil sendiri)
- Data seed sudah masuk (Decision D-3): 1 tenant (PT ABC F&B Company), 5 legal
  entity, 8 business unit, 1 team (Outlet Dago), 4 worker (Rina, Dedi, Sari,
  1 manajer), 2 Priority, 5 Driver, 10 Work Item, 8 checklist item, 1 blocker.
  Konten narasi diadopsi dari `data.js`; relasi dibangun ulang lewat FK asli,
  bukan string-matching seperti prototipe. Yang sengaja tidak diadopsi:
  array `sl` di halaman Fairness, `state.attain`, `state.okrs` (dead code),
  `state.initiatives` (tanpa data owner). Detail lengkap ada di komentar
  pembuka `009_seed_pt_abc_fb_company.sql`, termasuk daftar hal yang
  disintesis (bukan dari data.js) seperti nama lengkap legal entity dan
  satu akun manajer.
- Migration 013 menambah 2 worker lagi, role `executive` dan `hc_admin`,
  tanpa `team_id`/`position_id` (dua role ini memang tenant-wide di RLS,
  bukan milik satu tim). Nama lengkapnya ("Eksekutif ABC F&B Company", "HC
  ABC F&B Company") disintesis, bukan dari data.js, karena data.js tidak
  punya satu pun tokoh eksekutif atau HC bernama. Total sekarang 6 worker,
  6 akun demo.
- API layer sudah ada, lewat Supabase langsung (lihat bagian API di bawah)
- Migration 015 membuka profil perusahaan (tenant/organization/legal_entity/
  business_unit/team/position) dan data worker untuk ditulis dari aplikasi,
  bukan cuma dibaca. Edge Function `create_team_member` menambah anggota tim
  baru (akun login sungguhan + baris worker) tanpa perlu akses dashboard
  Supabase

## API

Tidak ada server terpisah. API-nya adalah Supabase itu sendiri, dua lapis:

**1. REST otomatis (PostgREST), untuk baca dan edit satu tabel**

Setiap tabel domain sudah terbuka lewat REST bawaan Supabase, dibatasi RLS
per tenant/role, contoh:

```
GET  /rest/v1/work_items?select=*,drivers(title)&status=eq.READY
PATCH /rest/v1/checklist_items?id=eq.<id>          { "done": true }
```

Base URL dan publishable key:

```
Project URL      : https://qfvvijwieqcazmovowiq.supabase.co
Publishable key  : sb_publishable_1enn_7PLmYTbH0z8e_Qg6Q_toklYicY
```

(Publishable/anon key ini aman ditaruh di client; setiap baris tetap
disaring lewat RLS berdasarkan identitas pengguna yang login, bukan lewat
key ini.)

**2. RPC (Postgres function), untuk aksi yang menyentuh lebih dari satu tabel**

RLS saja tidak cukup untuk aksi yang menurut CLAUDE.md harus "senyap di
belakang layar": tandai tugas selesai harus ikut menulis Evidence dan,
kalau tugas itu terhubung ke Driver, menambah `actual`-nya, sebagai satu
transaksi. Karena itu `drivers` sengaja tidak punya policy tulis sama
sekali; satu-satunya jalan `actual` berubah adalah lewat fungsi ini.

| Fungsi | Efek |
| --- | --- |
| `complete_work_item(p_work_item_id)` | Work Item -> DONE, tulis Evidence (SYSTEM_EVENT), tambah `drivers.actual` kalau item itu terhubung ke Driver |
| `raise_blocker(p_work_item_id, p_reason)` | Work Item -> BLOCKED, buat baris Blocker (OPEN) |
| `resolve_blocker(p_blocker_id)` | Blocker -> RESOLVED; kalau itu Blocker terbuka terakhir untuk Work Item-nya, Work Item kembali ke READY |
| `create_work_item(p_title_id, p_title_en, p_due_at, p_priority_level, p_owner_id)` | Buat Work Item baru, type TASK, status READY, tanpa `priority_id`/`driver_id` (quick add cuma pernah buat pekerjaan rutin, bukan pekerjaan prioritas, di prototipe statis juga begitu). `team_id`/`creator_id` diturunkan di server, bukan dari client |

Dipanggil lewat PostgREST juga, sebagai POST biasa:

```
POST /rest/v1/rpc/complete_work_item   { "p_work_item_id": "<uuid>" }
```

Keempatnya `SECURITY DEFINER`. Untuk `complete_work_item`/`raise_blocker`/
`resolve_blocker` itu perlu karena mereka menulis ke drivers/evidence yang
memang tidak boleh ditulis langsung oleh client. `create_work_item` beda
alasannya: `work_items_write` sebenarnya sudah mengizinkan INSERT langsung
lewat RLS, tapi `with check`-nya cuma memvalidasi `owner_id`, bukan
`creator_id`, jadi lewat POST langsung `creator_id` bisa diisi apa saja
oleh client; `team_id` juga harus benar padahal client tidak punya cara sah
untuk membacanya. Jadi `create_work_item` menurunkan `creator_id`/`team_id`
di server dari identitas pemanggil, pola yang sama dengan tiga RPC lain.
Semuanya cek otorisasi manual di dalam fungsi meniru aturan
`work_items_write` (pemilik, atau manager/executive/hc_admin), bukan
mengandalkan RLS. Sudah diuji langsung di database (transaksi yang
di-rollback): `complete_work_item` menambah `drivers.actual` dan menulis
Evidence serta audit_log dengan benar, `raise_blocker`/`resolve_blocker`
memindahkan status Work Item dengan benar, `create_work_item` membiarkan
Rina membuat tugas untuk dirinya sendiri dan manajer menugaskan ke Rina,
tapi menolak Dedi (karyawan) menugaskan ke Rina, judul kosong, dan
panggilan tanpa login. Sekarang juga terhubung dari `nusvapeople-task` sungguhan: layar
Pekerjaan Saya (workspace karyawan) dan Board Tim (workspace manajer, seluruh
task tim tanpa filter pemilik) login lewat `sb.auth.signInWithPassword`
memakai salah satu dari 6 akun demo di atas, satu sesi menghidupkan
keduanya, lalu membaca/menulis lewat jalur di atas. Seluruh frontend
sekarang digembok login di depan (bukan cuma dua rute itu); persona
Eksekutif dan HC ikut login memakai akun `executive`/`hc_admin` di atas,
tapi layar mereka (Beranda, Progres, Risiko, dst.) tetap membaca `data.js`
statis, login di situ murni penentu identitas dan persona awal, belum jadi
koneksi data live. Board Tim membuktikan
batas otorisasi lintas-pemilik: percobaan `complete_work_item` atau tulis
`checklist_items` pada task orang lain benar-benar ditolak, bukan cuma
disembunyikan di UI (`checklist_items` di-RLS sehingga update yang tidak sah
diam-diam diabaikan tanpa error, jadi frontend memuat ulang dan memeriksa
dulu sebelum mempercayai perubahan lokal). Diverifikasi lewat Playwright
memakai client Supabase tiruan dengan dua worker (Rina dan Dedi) untuk
menguji batas itu, karena sandbox pengujian sesi ini memblokir akses
jaringan keluar ke CDN maupun ke project Supabase secara langsung; jadi
verifikasi sungguhan di internet nyata (situs Vercel atau mesin lokal)
masih perlu dilakukan. Layar lain (Kalender, Progres, Review, Dashboard
organisasi) masih memakai `data.js` statis, belum tersambung.

Setiap insert/update/delete pada work_items, priorities, drivers,
checklist_items, blockers, dan business_outcomes sekarang otomatis tercatat
di `audit_log` (aktor, before/after) lewat trigger generik, tanpa perlu
kode tambahan di RPC manapun.

**3. Edge Function, untuk aksi yang butuh hak admin (service role)**

RLS dan RPC biasa jalan sebagai identitas caller yang login; tidak ada
keduanya yang boleh membuat akun Supabase Auth baru, karena itu butuh
service role key yang tidak boleh menyentuh browser. Satu-satunya jalan
resminya adalah Edge Function, yang jalan di server Supabase dan baru
memakai service role key setelah memvalidasi identitas dan peran pemanggil
lewat client ber-anon-key biasa (RLS tetap berlaku di langkah itu).

| Fungsi | Efek |
| --- | --- |
| `create_team_member` | Membuat akun Supabase Auth (`email` + kata sandi acak sekali pakai) dan baris `workers` baru dalam satu langkah. `manager` cuma boleh menambah role `employee` ke tim sendiri (team_id diturunkan otomatis dari worker pemanggil kalau tidak dikirim); `executive`/`hc_admin` boleh peran apa saja, tenant-wide. `tenant_id` selalu diturunkan dari worker pemanggil, tidak pernah dari input client. Kalau insert ke `workers` gagal setelah akun Auth terlanjur dibuat, akun itu dihapus lagi supaya tidak ada login yatim tanpa baris worker |

Dipanggil lewat `supabase-js`:

```js
const { data, error } = await sb.functions.invoke('create_team_member', {
  body: { full_name, email, role, team_id },
});
// data => { worker, email, temp_password }
```

Tidak ada infrastruktur email di Phase 1 ini, jadi `temp_password` dikembalikan
apa adanya ke pemanggil (manager/HC) supaya bisa dibagikan manual ke anggota
tim baru, pola yang sama dengan akun demo di atas. Otorisasi diuji manual
lewat pembacaan kode (bukan panggilan HTTP langsung): sandbox pengembangan
sesi ini tidak bisa memanggil Edge Function secara langsung (tidak ada akses
jaringan keluar), jadi verifikasi end-to-end sungguhan (lewat situs Vercel
atau mesin dengan akses internet) masih perlu dilakukan. Policy tulis RLS
untuk tabel profil perusahaan (migration 015) sudah diuji langsung di
database lewat transaksi yang di-rollback: manager berhasil mengubah nama
tim sendiri tapi ditolak saat mencoba mengubah nama tenant atau membuat tim
baru; executive/hc_admin berhasil di keduanya; karyawan ditolak di semuanya,
termasuk mengubah worker manapun (perubahan role/tim worker sengaja dibatasi
executive/hc_admin saja, karena RLS bekerja per-baris bukan per-kolom,
sehingga policy yang mengizinkan manager mengubah "worker di tim sendiri"
juga akan mengizinkan manager menaikkan peran anak buahnya sendiri).

## Cakupan Phase 1 (lihat dokumen desain untuk detail)

Termasuk: model tenant, otorisasi RLS, skema Work Item kanonik, Priority/
Driver/Commitment/Initiative sebagai objek nyata, Dependency/Blocker,
Evidence multi-tipe, audit trail, concurrency (optimistic locking), API
lewat PostgREST + RPC.

Ditambahkan di luar rencana Phase 1 awal, atas permintaan langsung: profil
perusahaan (tenant/organization/legal_entity/business_unit/team/position)
dan penambahan anggota tim (akun login sungguhan) bisa ditulis dari
aplikasi, bukan cuma dibaca dari seed data.

Di luar cakupan: Nexa AI asli, notifikasi, redesain UI frontend, koneksi live
untuk layar selain Pekerjaan Saya, Board Tim, dan profil perusahaan/anggota
tim (Kalender masih memakai `data.js` untuk sisi Progres/Prioritas, Review,
Dashboard organisasi).
