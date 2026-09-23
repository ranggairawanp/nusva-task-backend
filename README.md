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
- Belum ada API layer (REST/GraphQL/Edge Functions) di atas skema ini

## Cakupan Phase 1 (lihat dokumen desain untuk detail)

Termasuk: model tenant, otorisasi RLS, skema Work Item kanonik, Priority/
Driver/Commitment/Initiative sebagai objek nyata, Dependency/Blocker,
Evidence multi-tipe, audit trail, concurrency (optimistic locking).

Di luar cakupan: Nexa AI asli, notifikasi, redesain UI frontend.
