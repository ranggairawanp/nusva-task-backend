# Nusva People · Backend (Phase 1 Domain Foundation)

Backend Supabase (Postgres + Auth + Row Level Security) untuk Nusva People Work
Management. Repo ini terpisah dari
[`nusvapeople-task`](https://github.com/ranggairawanp/nusvapeople-task), yang
tetap menjadi prototipe frontend statis sesuai CLAUDE.md di repo itu.

Dokumen desain lengkap (model tenant, otorisasi, ERD, keputusan D-1/D-2/D-3):
lihat dokumen "Nusva People: Phase 1 Domain Foundation" yang dibagikan terpisah.

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
| `016_shifts_routines_and_handover.sql` | Tugas rutin per shift dan serah terima: tabel `shifts` dan `shift_handovers`, `recurring_templates` dihidupkan (title jsonb, `days_of_week` ISO 1-7 menggantikan `rrule`, shift, penanggung jawab, checklist), kolom `shift_id`/`occurrence_date` di `work_items` dengan unique index (template_id, occurrence_date). RPC `generate_routine_work` (idempoten, membuat instance hari ini, rentang kemarin sampai besok), `create_routine_template`, `set_routine_template_active`, `submit_shift_handover`. Zona waktu Asia/Jakarta |
| `017_seed_outlet_dago_shifts_and_routines.sql` | Seed Outlet Dago: shift Pagi 07.00-15.00 dan Sore 15.00-23.00, lima template rutin, satu catatan serah terima dari shift sore kemarin |
| `018_notification_reads.sql` | Status dibaca notifikasi per karyawan, sinkron antarperangkat: tabel `notification_reads` (kunci notifikasi dari frontend, tanpa isi notifikasi), policy SELECT hanya milik sendiri, RPC `mark_notifications_read(text[])` (maks. 200 kunci per panggilan, duplikat dan kunci kosong diabaikan) |
| `019_priority_checkins.sql` | Weekly Check-in Prioritas Utama: tabel `priority_checkins` (satu baris per prioritas per minggu, `week_start` Senin Asia/Jakarta, angka hasil, keyakinan ON_TRACK/WATCH/OFF_TRACK, catatan maks. 500 karakter, penginput), policy SELECT seluas tenant, RPC `submit_priority_checkin` (manajer untuk tim sendiri, eksekutif/HC seluruh tenant; isian ulang di minggu yang sama memperbarui baris; sekaligus mengisi `business_outcomes.current_value/reported_by/reported_at` dan menurunkan `priorities.status`, ACHIEVED kalau target terlampaui) |
| `020_sop_audit_photos.sql` | SOP dan audit outlet dengan foto: `recurring_templates.kind` (CHECKLIST/AUDIT), kolom `checklist_items.requires_photo/result/note/photo_path`, trigger penjaga item (flag foto tetap, temuan wajib catatan, foto di folder tugasnya), trigger syarat selesai (foto wajib dan penilaian audit lengkap, berlaku untuk semua jalur selesai), trigger tindak lanjut otomatis per temuan (HIGH, deadline besok 17.00 WIB, PIC manajer tim, `parent_work_id`), `generate_routine_work` membawa flag foto, RPC `create_routine_template_v2` dengan jenis, bucket privat `evidence-photos` (JPEG, maks. 2 MB) dengan policy upload pemilik tugas atau manajer+ dan baca seluas tenant. Seed: inspeksi higiene Outlet Dago jadi audit lima item, rekap kas sore mendapat foto slip setoran |
| `021_comments_and_approval.sql` | Komentar, mention, dan persetujuan tugas: tabel `work_item_comments` (kind COMMENT/SUBMITTED/APPROVED/CHANGES_REQUESTED, mention uuid[] disaring ke tenant, maks. 10), kolom `work_items.requires_approval/approval_status/approved_by/approved_at`, trigger penjaga kolom persetujuan (hanya lewat RPC, DONE ditolak sebelum disetujui), `complete_work_item` dengan cabang persetujuan (WAITING/PENDING, cek foto dan audit yang sama), RPC `set_work_item_approval`, `review_work_item` (APPROVE: DONE, evidence APPROVAL, angka Action Plan bertambah di sini; REQUEST_CHANGES: wajib catatan, kembali IN_PROGRESS; PIC tidak bisa menyetujui tugasnya sendiri), dan `add_work_item_comment` (anggota tim tugas atau manajer+). Seed: rekap kas Rina wajib disetujui, latihan kasir Dedi menunggu persetujuan, satu utas komentar dengan mention |
| `022_review_cycles.sql` | Siklus penilaian: tabel `review_cycles` (nama dwibahasa, tiga deadline: self-assessment, review manajer, kalibrasi; status OPEN/CLOSED; tahap siklus diturunkan aplikasi dari tanggal) dan `performance_reviews` (satu baris per karyawan per siklus, rating 0 sampai 3 untuk self/manajer/kalibrasi beserta catatan, pengisi, dan waktunya, potensi 0 sampai 2 untuk 9-box). SELECT dibatasi: karyawan hanya barisnya sendiri, manajer anggota timnya, eksekutif/HC seluruh tenant. Tulis hanya lewat RPC `submit_self_assessment` (karyawan sendiri, sebelum review manajer), `submit_manager_review` (manajer tim atau eksekutif/HC, bukan diri sendiri, setelah self-assessment, sebelum kalibrasi), `calibrate_review` (rating akhir, default rating manajer). Trigger di `workers` menambahkan karyawan baru ke siklus yang terbuka. Seed: Semester 2 2026, Rina belum mengisi, Dedi sudah self-assessment, Sari sudah direview manajer |
| `023_multi_outlet_and_executive_overview.sql` | Multi-outlet: tiga tim baru (Outlet Cimahi di OTU · Cimahi, Outlet Buah Batu di OTS · Bandung Selatan, Outlet Cirebon di OTS · Cirebon), masing-masing satu manajer dan dua karyawan dengan akun demo, Prioritas Utama dengan angka hasil dan Action Plan, riwayat Weekly Check-in tiga minggu (juga untuk Outlet Dago), dan tugas dengan keadaan berbeda. Izin manajer dipersempit ke tim sendiri lewat helper `can_manage_work_item(owner, team)` di policy `work_items`, `checklist_items`, upload foto bukti, serta RPC `complete_work_item`, `raise_blocker`, `resolve_blocker`; `create_work_item` menolak manajer yang menugaskan ke tim lain. RPC `executive_overview()` (eksekutif/HC) mengembalikan per tim: entitas, unit bisnis, jumlah anggota, hitungan tugas (aktif, terlambat, terkendala, menunggu persetujuan, selesai 7 hari dan tepat waktu), tindak lanjut audit terbuka, audit terakhir, dan Prioritas Utama beserta Action Plan dan riwayat check-in |
| `024_reanchor_dago_demo_tasks.sql` | Perapian data demo sekali jalan, seperti 012: deadline 10 tugas seed Outlet Dago digeser relatif dari tanggal migration diterapkan (tiga hari ini, tiga besok, satu kemarin, semua 17.00 WIB; tiga tugas DONE diberi `completed_at` hari ini sebelum deadline). Tugas rutin tidak disentuh |
| `025_daily_demo_deadline_refresh.sql` | Job harian pg_cron `nusva-demo-deadlines` (22.01 UTC, 05.01 WIB) yang memanggil `refresh_demo_deadlines()`: deadline dan waktu selesai 23 tugas demo (Dago dan tiga outlet 023) digeser relatif ke hari ini sesuai tabel `demo_task_anchors`. Status tidak pernah diubah, tugas rutin tidak disentuh, fungsi tidak bisa dipanggil dari aplikasi. Tugas demo baru cukup ditambah barisnya di `demo_task_anchors`. Menghentikan: `select cron.unschedule('nusva-demo-deadlines');` |
| `026_demo_checkin_refresh.sql` | Job harian yang sama (`refresh_demo_deadlines()`) kini juga menggeser 21 Weekly Check-in demo (tabel `demo_checkin_anchors`, posisi 1 sampai 3 minggu sebelum minggu berjalan) dan `reported_at` angka hasil bisnisnya. Minggu berjalan dibiarkan kosong untuk diisi manajer. Prioritas yang sudah punya check-in nyata tidak digeser lagi (data nyata menang, sekaligus mencegah bentrok unique). Pergeseran dua langkah lewat minggu penampung di satu transaksi |
| `027_hc_overview.sql` | Dashboard HC live Tahap 1a. RPC `hc_overview(p_level)` (eksekutif/HC) mengembalikan angka agregat saja, tanpa nama atau baris per orang: kesiapan kalibrasi, sebaran rating, bukti dari tugas, perubahan saat kalibrasi, selisih antarpenilai (minimal 5 penilaian per penilai), ritme Weekly Check-in 4 minggu, tim dengan target, dan praktik per outlet. Kelompok di bawah `tenants.hc_min_group` (bawaan 10) ditahan, termasuk penahanan kedua kalau hanya satu kelompok kecil; tingkat outlet hanya terbuka di area yang semua outletnya lolos ambang. Setiap panggilan dicatat di `audit_log` (READ). Policy SELECT `audit_log` dipersempit ke hc_admin. Kolom `workers.is_demo` hanya bisa diubah dari migration (trigger `guard_worker_is_demo`) |
| `028_seed_hc_demo_people.sql` | 39 karyawan demo (`is_demo`, email `demo.hcNN@demo.nusvapeople.local`, password acak tidak disimpan sehingga tidak bisa login) supaya tiap outlet berisi 12 karyawan. Penilaian siklus terbuka diisi (Cimahi longgar, Cirebon ketat, sebagian sudah dikalibrasi), riwayat tugas rutin Juli sampai Agustus sebagai bukti (di luar jendela tampilan aplikasi), tiga template "Checklist buka outlet" yang dijeda, dan Weekly Check-in minggu ke-4 untuk enam prioritas. Pembersihan manual: `supabase/scripts/cleanup_hc_demo_people.sql` |
| `029_edit_work_item.sql` | Ubah tugas dari aplikasi lewat RPC `update_work_item()` (nama, keterangan, deadline, prioritas tugas, PIC). Hanya pemilik, manajer tim tugas itu, atau eksekutif/HC; tugas selesai atau yang menunggu persetujuan tidak bisa diubah; nama tugas rutin mengikuti template; ganti PIC hanya untuk manajer ke atas dan tetap di tim yang sama; Action Plan dan kolom persetujuan tidak disentuh. Kolom baru `work_items.updated_by` diisi trigger untuk setiap perubahan dari sesi login, jadi pengubah terakhir tercatat |
| `030_hc_transparency.sql` | Halaman "Apa yang dilihat HC" (Tahap 1b, tayang lebih dulu). RPC `hc_transparency()` untuk semua pekerja yang login: ambang kelompok tenant, berapa kali dashboard HC dibuka 30 hari terakhir, berapa orang yang membuka per peran, tanggal terakhir dibuka, dan jumlah karyawan di siklus penilaian. Hanya hitungan dari `audit_log`, tanpa nama; `audit_log` tetap hanya terbaca HC |

**Status 016 dan 017:** sudah diuji dengan memutar ulang migration 001 sampai 017 di
Postgres 16 lokal (dengan stub `auth.users`/`auth.uid()`), termasuk uji RPC dan RLS per
peran. **Sudah diterapkan ke project Supabase aktif** (4 Oktober 2026), lalu diverifikasi
dengan sesi `authenticated` simulasi: `generate_routine_work` membuat instance hari ini dan
idempoten di panggilan kedua, karyawan ditolak saat membuat template, `submit_shift_handover`
mencatat penulis dari pemanggil. Versi 016 yang diterapkan tidak memakai `DROP COLUMN`
(kolom `rrule` dibiarkan nullable) supaya tidak tertahan konfirmasi statement destruktif. Frontend mendeteksi sendiri apakah 016 sudah
ada (lewat `generate_routine_work`) dan menyembunyikan fitur rutin kalau belum, jadi urutan
deploy frontend dan backend tidak saling bergantung.

**Status 018:** diuji dengan memutar ulang 001 sampai 018 di Postgres 16 lokal: karyawan
hanya melihat baris sendiri, duplikat dan kunci kosong diabaikan, lebih dari 200 kunci ditolak,
anon tidak bisa memanggil RPC, insert langsung ditolak RLS meski role punya hak INSERT seperti
default Supabase. **Sudah diterapkan ke project Supabase aktif** dan diuji ulang di sana dengan
sesi Rina dalam transaksi yang di-rollback. Versi yang diterapkan tidak memuat pembersihan baris
lebih tua dari 60 hari: perintah DELETE di dalam fungsi membuat `apply_migration` tertahan
konfirmasi statement destruktif sampai timeout. Pembersihan menyusul sebagai tugas terjadwal.
Frontend tetap mendeteksi sendiri: kalau `notification_reads` tidak ada, status dibaca disimpan
lokal per perangkat.

**Status 019:** diuji dengan memutar ulang 001 sampai 019 di Postgres 16 lokal: karyawan ditolak,
manajer bisa check-in dan isian kedua di minggu yang sama memperbarui baris yang ada, keyakinan
tidak valid ditolak, eksekutif bisa, status ACHIEVED terpasang saat target terlampaui, insert
langsung dan anon ditolak. **Sudah diterapkan ke project Supabase aktif** dan diuji ulang di sana
(sesi manajer dan Rina dalam transaksi yang di-rollback). Frontend mendeteksi sendiri: kalau
`priority_checkins` tidak ada, Progres tetap live dan bagian Weekly Check-in disembunyikan.

**Status 020:** diuji dengan memutar ulang 001 sampai 019 di Postgres 16 lokal (dengan skema
`storage` tiruan), membuat instance hari ini, lalu menerapkan 020: selesai tanpa foto ditolak,
temuan tanpa catatan ditolak, flag foto tidak bisa diubah, foto di folder lain ditolak, upload ke
tugas orang lain dan tenant lain ditolak, audit yang belum lengkap ditolak, audit lengkap membuat
tindak lanjut untuk manajer, tugas biasa tetap bisa diselesaikan seperti sebelumnya, v2 menolak
karyawan, anon, jenis tidak valid, dan audit tanpa item. **Sudah diterapkan ke project Supabase
aktif** dan alur penuh diuji ulang di sana dengan sesi Sari dalam transaksi yang di-rollback.
Frontend mendeteksi sendiri: kalau kolom `requires_photo` tidak ada, checklist lama tetap dipakai.

**Status 021:** diuji dengan memutar ulang 001 sampai 021 di Postgres 16 lokal: PATCH langsung ke
kolom persetujuan atau status DONE ditolak, kirim untuk persetujuan, kirim dua kali ditolak, PIC
menyetujui sendiri ditolak, mention ke worker di luar tenant dibuang, komentar kosong dan insert
langsung ditolak, revisi tanpa catatan ditolak, revisi lalu kirim ulang lalu disetujui, angka Action
Plan baru bertambah saat disetujui, karyawan tidak bisa mengatur persetujuan, tugas biasa tetap
selesai normal, anon ditolak. **Sudah diterapkan ke project Supabase aktif** dan alurnya diuji ulang
di sana dengan sesi Rina dan manajer dalam transaksi yang di-rollback.

**Status 022:** diuji dengan memutar ulang 001 sampai 022 di Postgres 16 lokal: karyawan hanya
melihat barisnya sendiri, mengisi self-assessment orang lain ditolak, rating di luar 0 sampai 3
ditolak, UPDATE langsung ditolak, karyawan tidak bisa mereview diri sendiri atau rekan, manajer
mereview dan mengkalibrasi anggota timnya, review ulang setelah kalibrasi ditolak, self-assessment
setelah review manajer ditolak, HC melihat seluruh tenant, karyawan baru otomatis masuk siklus.
**Sudah diterapkan ke project Supabase aktif** dan diuji ulang di sana dengan sesi Rina dalam
transaksi yang di-rollback.

**Status 023:** diuji dengan memutar ulang 001 sampai 023 di Postgres 16 lokal: manajer Cimahi
ditolak saat menyelesaikan atau memberi kendala pada tugas Dago, UPDATE langsung ke tugas Dago tidak
mengenai satu baris pun, menugaskan ke anggota tim lain ditolak, tugas tim sendiri tetap bisa
diselesaikan, manajer Dago tetap bisa bekerja di timnya, `executive_overview` ditolak untuk manajer
dan mengembalikan 4 tim untuk eksekutif. **Sudah diterapkan ke project Supabase aktif** dan diuji
ulang di sana dengan sesi eksekutif dalam transaksi yang di-rollback. Akun demo baru:
manajer.cimahi, andi, wulan, manajer.buahbatu, fajar, nina, manajer.cirebon, yusuf, lestari
(semua `@demo.nusvapeople.local`, password sama dengan akun demo lain).

Zona waktu `Asia/Jakarta` ditulis di fungsi 016 karena satu-satunya tenant ada di Bandung.
Kalau ada tenant di zona lain, pindahkan zona ke kolom `tenants`.

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
