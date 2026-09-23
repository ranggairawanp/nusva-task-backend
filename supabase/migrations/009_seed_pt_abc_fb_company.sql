-- Seed content adopted from nusvapeople-task/data.js (Decision D-3, option c):
-- the narrative content (priorities, drivers, tasks, checklists, org labels) is
-- adopted as-is, but the underlying relationships are rebuilt as real foreign
-- keys instead of data.js's disconnected string-matching keys (driver:'d1',
-- unit:'otu', entity prefixes in unit labels).
--
-- Explicitly NOT adopted, per D-3 and "don't invent data":
--   - the Fairness page's hardcoded `sl` array
--   - `state.attain` (org-wide series presented as if per-entity)
--   - `state.okrs` (confirmed dead code, superseded by priorities/drivers)
--   - `state.initiatives` (no owner in source data; not fabricated here)
--   - commitments / commitment_checkins (no such object exists in data.js)
--   - evidence (must come from real app writes, not a synthetic backfill)
--   - dependencies (none present in source data)
--
-- Things synthesized here that are NOT in data.js, disclosed explicitly:
--   - full names for legal entities hq/dpr/gdl/otu/ots (data.js only carries
--     the entity code and unit-label prefixes such as "OTU · Bandung Utara")
--   - one manager account/worker/position (data.js's reviewCycle implies a
--     manager stage exists, but no manager is named)
--   - the "Outlet Dago" team boundary (inferred from task titles that name
--     "outlet Dago" directly; task 1 and task 10)
--   - the blocker reason on task 3 (built from the task title plus driver
--     d3's `dep` field, which names the blocking team but not a reason
--     sentence)
--   - concrete due_at timestamps for the 'today' / 'tomorrow' / 'overdue'
--     buckets, anchored to TODAY_ISO = 2026-09-12, Asia/Jakarta
--   - completed_at is left NULL even for tasks marked done in data.js,
--     since data.js records no completion timestamp

-- 1. Demo auth identities (email/password, local Supabase seed pattern)
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at,
  raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at,
  confirmation_token, email_change, email_change_token_new, recovery_token
) values
  ('00000000-0000-0000-0000-000000000000', '50000000-0000-0000-0000-000000000001', 'authenticated', 'authenticated',
   'rina@demo.nusvapeople.local', crypt('NusvaDemo2026!', gen_salt('bf')), now(), now(),
   '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '50000000-0000-0000-0000-000000000002', 'authenticated', 'authenticated',
   'dedi@demo.nusvapeople.local', crypt('NusvaDemo2026!', gen_salt('bf')), now(), now(),
   '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '50000000-0000-0000-0000-000000000003', 'authenticated', 'authenticated',
   'sari@demo.nusvapeople.local', crypt('NusvaDemo2026!', gen_salt('bf')), now(), now(),
   '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '50000000-0000-0000-0000-000000000004', 'authenticated', 'authenticated',
   'manajer.dago@demo.nusvapeople.local', crypt('NusvaDemo2026!', gen_salt('bf')), now(), now(),
   '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '');

insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
values
  (gen_random_uuid(), '50000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001',
   '{"sub":"50000000-0000-0000-0000-000000000001","email":"rina@demo.nusvapeople.local"}'::jsonb, 'email', now(), now(), now()),
  (gen_random_uuid(), '50000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000002',
   '{"sub":"50000000-0000-0000-0000-000000000002","email":"dedi@demo.nusvapeople.local"}'::jsonb, 'email', now(), now(), now()),
  (gen_random_uuid(), '50000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000003',
   '{"sub":"50000000-0000-0000-0000-000000000003","email":"sari@demo.nusvapeople.local"}'::jsonb, 'email', now(), now(), now()),
  (gen_random_uuid(), '50000000-0000-0000-0000-000000000004', '50000000-0000-0000-0000-000000000004',
   '{"sub":"50000000-0000-0000-0000-000000000004","email":"manajer.dago@demo.nusvapeople.local"}'::jsonb, 'email', now(), now(), now());

-- 2. Tenant / organization
insert into tenants (id, name) values
  ('00000000-0000-0000-0000-000000000001', 'PT ABC F&B Company');

insert into organizations (id, tenant_id, name) values
  ('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', 'PT ABC F&B Company');

-- 3. Legal entities (data.js only carries the code; full names inferred from
-- the unit-label prefixes it uses elsewhere, e.g. "OTU · Bandung Utara")
insert into legal_entities (id, tenant_id, organization_id, code, name) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', 'hq', 'Kantor Pusat'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', 'dpr', 'Dapur Produksi'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', 'gdl', 'Gudang & Logistik'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', 'otu', 'Outlet Utara'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', 'ots', 'Outlet Selatan');

-- 4. Business units (bilingual names verbatim from data.js `units[]`)
insert into business_units (id, tenant_id, legal_entity_id, name) values
  ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000004', '{"id":"OTU · Bandung Utara","en":"OTU · North Bandung"}'),
  ('20000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000004', '{"id":"OTU · Cimahi","en":"OTU · Cimahi"}'),
  ('20000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000005', '{"id":"OTS · Bandung Selatan","en":"OTS · South Bandung"}'),
  ('20000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000005', '{"id":"OTS · Cirebon","en":"OTS · Cirebon"}'),
  ('20000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', '{"id":"DPR · Lini Produksi A","en":"DPR · Production Line A"}'),
  ('20000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', '{"id":"DPR · Lini Produksi B","en":"DPR · Production Line B"}'),
  ('20000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000003', '{"id":"GDL · Distribusi Cikarang","en":"GDL · Cikarang Distribution"}'),
  ('20000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '{"id":"HQ · Keuangan & Umum","en":"HQ · Finance & General"}');

-- 5. Team (the only team with real Work Items in data.js: all tasks and all
-- three named reviews sit under unit 'otu', and two task titles name
-- "outlet Dago" directly)
insert into teams (id, tenant_id, business_unit_id, name) values
  ('30000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'Outlet Dago');

-- 6. Positions (titles from data.js `reviews[].role`, plus one synthesized manager title)
insert into positions (id, tenant_id, team_id, title) values
  ('40000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'Shift lead, outlet Dago'),
  ('40000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'Kasir & pelatihan'),
  ('40000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'Inspeksi & higiene'),
  ('40000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'Manajer outlet');

-- 7. Workers
insert into workers (id, tenant_id, position_id, team_id, auth_user_id, full_name, role) values
  ('60000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001', 'Rina', 'employee'),
  ('60000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002', 'Dedi', 'employee'),
  ('60000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000003', '30000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003', 'Sari', 'employee'),
  ('60000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000004', '30000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000004', 'Manajer Outlet Dago', 'manager');

-- 8. Business Outcomes (every number states its origin: reported_by/reported_at,
-- from data.js `priorities[].outcome.by`/`.at`)
insert into business_outcomes (id, tenant_id, baseline, target, current_value, period, unit, label, reported_by, reported_at) values
  ('70000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 61, 75, 68.4, '2026-12-31', '%',
   '{"id":"Persentase outlet capai target harian","en":"Share of outlets hitting daily target"}', '60000000-0000-0000-0000-000000000001', '2026-09-11'),
  ('70000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', 82, 95, 96, '2026-09-30', null,
   '{"id":"Skor audit higiene rata-rata","en":"Average hygiene audit score"}', null, '2026-09-09');
-- p2's outcome is attributed to "Auditor QA" in data.js, which is a role, not a named
-- worker in this seed; reported_by is left NULL rather than invented.

-- 9. Priorities (max 2 per team, enforced by trigger; both go on Outlet Dago,
-- the only team in this seed)
insert into priorities (id, tenant_id, team_id, business_outcome_id, scope, status, statement) values
  ('80000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001', 'TEAM', 'AT_RISK',
   '{"id":"Outlet capai target harian: dari 61% ke 75% pada 31 Des 2026","en":"Outlets hitting daily target: from 61% to 75% by 31 Dec 2026"}'),
  ('80000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000002', 'TEAM', 'ACHIEVED',
   '{"id":"Skor audit higiene: dari 82 ke 95 pada 30 Sept 2026","en":"Hygiene audit score: from 82 to 95 by 30 Sept 2026"}');

-- 10. Drivers (max 3 per priority, enforced by trigger; p1 has exactly 3, p2 has 2)
insert into drivers (id, tenant_id, priority_id, title, hypothesis, target, actual, unit) values
  ('90000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000001',
   '{"id":"Upsell terstruktur per transaksi","en":"Structured upsell per transaction"}',
   '{"id":"Kalau tiap outlet melakukan upsell terstruktur ke 40 transaksi per hari, persentase outlet capai target naik karena rata-rata tiket naik 8 sampai 12 persen","en":"If every outlet runs a structured upsell on 40 transactions a day, the share of outlets on target rises because average ticket grows 8 to 12 percent"}',
   1200, 1284, '{"id":"transaksi","en":"transactions"}'),
  ('90000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000001',
   '{"id":"Briefing shift 10 menit","en":"10-minute shift briefing"}',
   '{"id":"Kalau setiap shift dibuka dengan briefing 10 menit, kesalahan pesanan turun dan target harian lebih sering tercapai","en":"If every shift opens with a 10-minute briefing, order errors fall and daily targets are hit more often"}',
   30, 26, '{"id":"sesi","en":"sessions"}'),
  ('90000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000001',
   '{"id":"Stok bahan upsell tersedia sebelum jam 10","en":"Upsell stock ready before 10.00"}',
   '{"id":"Kalau bahan upsell tersedia sebelum jam 10, upsell bisa dijalankan sepanjang jam sibuk","en":"If upsell stock is ready before 10.00, upsell runs through the whole peak"}',
   18, 14, '{"id":"hari","en":"days"}'),
  ('90000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000002',
   '{"id":"Checklist penutupan dapur terverifikasi","en":"Verified kitchen closing checklist"}',
   '{"id":"Kalau checklist penutupan diverifikasi tiap malam, temuan audit turun","en":"If the closing checklist is verified nightly, audit findings fall"}',
   126, 126, '{"id":"checklist","en":"checklists"}'),
  ('90000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000002',
   '{"id":"Inspeksi silang antar outlet","en":"Cross-outlet inspection"}',
   '{"id":"Kalau outlet saling inspeksi tiap minggu, standar menyebar lebih cepat","en":"If outlets inspect each other weekly, standards spread faster"}',
   6, 6, '{"id":"inspeksi","en":"inspections"}');

-- 11. Work Items. data.js kind:'pledge' -> ACTION (a driver-tied commitment),
-- kind:'work' -> TASK. lane:'goal' items carry priority_id/driver_id, so their
-- completion feeds a Driver's `actual` (Performance evidence); lane:'routine'
-- items carry neither, per CLAUDE.md's WORK/PERFORMANCE split.
-- status: todo->READY, doing->IN_PROGRESS, blocked->BLOCKED, done->DONE.
-- due: today->2026-09-12, tomorrow->2026-09-13, overdue->2026-09-10 (all 17:00 WIB).
insert into work_items (id, tenant_id, team_id, type, title, creator_id, owner_id, status, priority_level, due_at, priority_id, driver_id, qty) values
  ('a0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'ACTION',
   '{"id":"Briefing shift pagi dan sore, outlet Dago","en":"Morning and evening shift briefing, Dago outlet"}',
   '60000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', 'IN_PROGRESS', 'HIGH', '2026-09-12 17:00:00+07',
   '80000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000002', 2),
  ('a0000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'ACTION',
   '{"id":"Upsell paket minum ke 40 transaksi hari ini","en":"Upsell drink bundle on 40 transactions today"}',
   '60000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', 'IN_PROGRESS', 'HIGH', '2026-09-12 17:00:00+07',
   '80000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001', 40),
  ('a0000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'TASK',
   '{"id":"Konfirmasi stok sirup dan topping ke Pengadaan","en":"Confirm syrup and topping stock with Procurement"}',
   '60000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', 'BLOCKED', 'URGENT', '2026-09-12 17:00:00+07',
   '80000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000003', 1),
  ('a0000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'TASK',
   '{"id":"Latih kasir baru skrip upsell 3 kalimat","en":"Train new cashier on the 3-line upsell script"}',
   '60000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000002', 'READY', 'NORMAL', '2026-09-13 17:00:00+07',
   '80000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001', 1),
  ('a0000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'TASK',
   '{"id":"Verifikasi checklist penutupan Jumat","en":"Verify Friday closing checklist"}',
   '60000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', 'DONE', 'NORMAL', '2026-09-12 17:00:00+07',
   '80000000-0000-0000-0000-000000000002', '90000000-0000-0000-0000-000000000004', 1),
  ('a0000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'TASK',
   '{"id":"Inspeksi silang ke outlet Setiabudi","en":"Cross inspection at Setiabudi outlet"}',
   '60000000-0000-0000-0000-000000000003', '60000000-0000-0000-0000-000000000003', 'READY', 'NORMAL', '2026-09-13 17:00:00+07',
   '80000000-0000-0000-0000-000000000002', '90000000-0000-0000-0000-000000000005', 1),
  ('a0000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'TASK',
   '{"id":"Rekap kas harian dan setor","en":"Daily cash reconciliation and deposit"}',
   '60000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', 'READY', 'NORMAL', '2026-09-12 17:00:00+07',
   null, null, null),
  ('a0000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'TASK',
   '{"id":"Input absensi shift ke Nusva People","en":"Enter shift attendance into Nusva People"}',
   '60000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', 'DONE', 'LOW', '2026-09-12 17:00:00+07',
   null, null, null),
  ('a0000000-0000-0000-0000-000000000009', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'TASK',
   '{"id":"Pesan bahan baku mingguan","en":"Order weekly raw materials"}',
   '60000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000002', 'IN_PROGRESS', 'HIGH', '2026-09-10 17:00:00+07',
   null, null, null),
  ('a0000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'TASK',
   '{"id":"Servis mesin kopi outlet Dago","en":"Service coffee machine, Dago outlet"}',
   '60000000-0000-0000-0000-000000000003', '60000000-0000-0000-0000-000000000003', 'READY', 'LOW', '2026-09-13 17:00:00+07',
   null, null, null);

-- 12. Checklist items (task 7 and task 10 in data.js)
insert into checklist_items (id, tenant_id, work_item_id, title, done, position) values
  ('b0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000007', '{"id":"Hitung kas laci","en":"Count till cash"}', true, 0),
  ('b0000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000007', '{"id":"Cocokkan dengan sistem kasir","en":"Reconcile with POS system"}', true, 1),
  ('b0000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000007', '{"id":"Setor ke brankas","en":"Deposit into the safe"}', false, 2),
  ('b0000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000007', '{"id":"Foto slip setoran","en":"Photograph the deposit slip"}', false, 3),
  ('b0000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000010', '{"id":"Bersihkan grup head","en":"Clean the group head"}', false, 0),
  ('b0000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000010', '{"id":"Ganti gasket jika perlu","en":"Replace the gasket if needed"}', false, 1),
  ('b0000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000010', '{"id":"Uji tekanan boiler","en":"Test boiler pressure"}', false, 2),
  ('b0000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000010', '{"id":"Catat hasil servis","en":"Log the service result"}', false, 3);

-- 13. Blocker on task 3. data.js records this task as status:'blocked' and its
-- driver (d3) names the blocking team via `dep`, but gives no reason sentence;
-- the reason text here is synthesized from the task title and that `dep` field.
insert into blockers (id, tenant_id, work_item_id, reason, raised_by, status) values
  ('c0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000003',
   'Menunggu konfirmasi stok sirup dan topping dari Tim Pengadaan Gudang & Logistik', '60000000-0000-0000-0000-000000000001', 'OPEN');
