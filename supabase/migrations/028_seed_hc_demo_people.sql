-- Data demo untuk dashboard HC live (keputusan K1 rancangan versi 3, 6 Oktober 2026).
--
-- Keputusan desain:
-- 1. Dengan 9 karyawan, ambang privasi 10 orang menahan hampir semua angka HC. Migration ini
--    menambah 39 karyawan demo sehingga tiap outlet berisi 12 karyawan (48 total, 24 per
--    area OTU dan OTS). Semuanya workers.is_demo = true dan memakai email
--    demo.hcNN@demo.nusvapeople.local.
-- 2. Akun auth dibuat dengan pola migration 023 (SQL langsung ke auth.users), bukan lewat Edge
--    Function, supaya seed bisa direview dan diulang. Password tiap akun acak dan tidak
--    disimpan di mana pun, jadi akun ini tidak bisa dipakai login. Akun demo yang dibagikan
--    (Rina, manajer, eksekutif, HC, dan seterusnya) tidak berubah.
-- 3. Penilaian di siklus terbuka diisi supaya dashboard punya cerita yang jujur:
--    Outlet Cimahi longgar (rating manajer tinggi, beberapa diturunkan saat kalibrasi),
--    Outlet Cirebon ketat (beberapa dinaikkan saat kalibrasi), Dago dan Buah Batu di tengah.
--    Buah Batu dan Cirebon semua karyawan demonya sudah direview, Dago dan Cimahi belum,
--    sehingga di tingkat outlet hanya area OTS yang lolos ambang. Baris penilaian akun demo
--    yang dibagikan tidak disentuh.
-- 4. Bukti dipakai dari riwayat tugas rutin Juli sampai Agustus 2026 (kepatuhan SOP). Aplikasi
--    tidak memuat instance rutin yang lebih tua dari kemarin, dan executive_overview() juga
--    tidak menghitungnya, jadi riwayat ini tidak muncul di Tugas Saya, Tugas Tim, atau angka
--    Action Plan. Tidak ada tugas Action Plan demo yang ditambahkan, supaya angka Progres
--    tidak menggelembung.
-- 5. Outlet Cimahi, Buah Batu, dan Cirebon belum punya tugas rutin, jadi masing-masing diberi
--    satu template "Checklist buka outlet" yang dijeda. Template dijeda tidak menghasilkan
--    tugas harian; ia hanya menjadi induk riwayat dan tampil "Dijeda" di Tugas Rutin.
-- 6. Satu Weekly Check-in minggu ke-4 ditambahkan ke enam dari tujuh prioritas (Cimahi waktu
--    tunggu sengaja tidak), didaftarkan di demo_checkin_anchors supaya ikut digeser job
--    harian. Ritme "4 minggu berturut-turut" jadi 6 dari 7 prioritas.
-- 7. Pembersihan: supabase/scripts/cleanup_hc_demo_people.sql (tidak dijalankan otomatis).
-- 8. Tidak ada DROP, REVOKE ALL, atau DELETE.

create temporary table hc_demo_people (
  n integer primary key,
  full_name text not null,
  team_id uuid not null,
  position_id uuid not null,
  self_rating smallint,
  mgr_rating smallint,
  calib_rating smallint,
  potential smallint not null,
  evidence integer not null
);

insert into hc_demo_people values
  -- Outlet Dago (OTU): 8 dari 9 sudah direview manajer
  ( 1, 'Bayu Saputra',      '30000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 1, 1, null, 1, 4),
  ( 2, 'Citra Lestiani',    '30000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000002', 2, 2, null, 2, 5),
  ( 3, 'Dimas Pratama',     '30000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000003', 1, 1, null, 1, 2),
  ( 4, 'Eka Rahmawati',     '30000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000002', 1, 2, null, 2, 4),
  ( 5, 'Galih Nugraha',     '30000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 1, 1, null, 0, 1),
  ( 6, 'Hana Salsabila',    '30000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000003', 2, 2, null, 2, 6),
  ( 7, 'Indra Wijaya',      '30000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000002', 0, 0, null, 0, 1),
  ( 8, 'Jihan Aulia',       '30000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 1, 1, null, 1, 3),
  ( 9, 'Kevin Ardiansyah',  '30000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000003', 1, null, null, 1, 0),
  -- Outlet Cimahi (OTU): manajer longgar, 8 dari 10 direview, 6 sudah dikalibrasi
  (10, 'Laras Ayuningtyas', '30000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000006', 2, 3, 2, 2, 3),
  (11, 'Mahesa Putra',      '30000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000007', 2, 2, 2, 1, 2),
  (12, 'Nadia Kusuma',      '30000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000007', 1, 2, 1, 1, 1),
  (13, 'Oki Firmansyah',    '30000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000006', 2, 3, 3, 2, 5),
  (14, 'Putri Anggraini',   '30000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000007', 1, 2, 1, 1, 2),
  (15, 'Rizky Ramadhan',    '30000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000006', 2, 2, null, 1, 4),
  (16, 'Salma Nuraini',     '30000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000007', 1, 2, 2, 1, 3),
  (17, 'Teguh Santoso',     '30000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000007', 2, 2, null, 0, 1),
  (18, 'Utami Dewi',        '30000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000006', 1, null, null, 1, 0),
  (19, 'Vino Hidayat',      '30000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000007', null, null, null, 1, 0),
  -- Outlet Buah Batu (OTS): semua direview, 5 dikalibrasi
  (20, 'Wahyu Setiawan',    '30000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000009', 1, 1, 1, 1, 4),
  (21, 'Yasmin Azzahra',    '30000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000009', 2, 2, 2, 2, 5),
  (22, 'Zaki Maulana',      '30000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000010', 1, 1, null, 1, 3),
  (23, 'Anisa Fitriani',    '30000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000010', 1, 1, 1, 1, 3),
  (24, 'Bagas Prakoso',     '30000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000010', 0, 1, 0, 0, 1),
  (25, 'Clara Wulandari',   '30000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000009', 2, 2, null, 2, 6),
  (26, 'Danu Kurniawan',    '30000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000010', 1, 1, null, 1, 2),
  (27, 'Elsa Permata',      '30000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000009', 1, 2, 2, 2, 4),
  (28, 'Farhan Akbar',      '30000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000010', 1, 1, null, 0, 3),
  (29, 'Gita Puspita',      '30000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000009', 2, 1, null, 1, 3),
  -- Outlet Cirebon (OTS): manajer ketat, semua direview, 5 dikalibrasi
  (30, 'Hendra Gunawan',    '30000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000012', 1, 1, 1, 1, 3),
  (31, 'Intan Maharani',    '30000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000012', 2, 1, 2, 2, 5),
  (32, 'Joko Susilo',       '30000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000013', 1, 0, null, 0, 1),
  (33, 'Kirana Larasati',   '30000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000012', 2, 1, null, 1, 4),
  (34, 'Lutfi Hakim',       '30000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000013', 1, 1, 1, 1, 3),
  (35, 'Maya Anggraeni',    '30000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000013', 1, 0, 1, 1, 2),
  (36, 'Naufal Rasyid',     '30000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000012', 1, 1, null, 1, 3),
  (37, 'Oktaviani Putri',   '30000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000013', 2, 1, null, 1, 4),
  (38, 'Panji Wicaksono',   '30000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000013', 0, 0, null, 0, 0),
  (39, 'Ratna Ningsih',     '30000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000012', 1, 1, 1, 2, 5);

-- Akun auth dengan password acak yang tidak disimpan: tidak bisa dipakai login.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at,
  raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at,
  confirmation_token, email_change, email_change_token_new, recovery_token
)
select '00000000-0000-0000-0000-000000000000',
       ('52000000-0000-0000-0000-' || lpad(p.n::text, 12, '0'))::uuid, 'authenticated', 'authenticated',
       'demo.hc' || lpad(p.n::text, 2, '0') || '@demo.nusvapeople.local',
       crypt(gen_random_uuid()::text || gen_random_uuid()::text, gen_salt('bf')), now(), null,
       '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', ''
  from hc_demo_people p;

insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), u.id, u.id::text, jsonb_build_object('sub', u.id::text, 'email', u.email), 'email', null, now(), now()
  from auth.users u
 where u.id in (select ('52000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid from hc_demo_people);

-- Trigger add_worker_to_open_cycles otomatis membuat baris penilaian di siklus terbuka.
insert into workers (id, tenant_id, position_id, team_id, auth_user_id, full_name, role, is_demo)
select ('62000000-0000-0000-0000-' || lpad(p.n::text, 12, '0'))::uuid, '00000000-0000-0000-0000-000000000001',
       p.position_id, p.team_id, ('52000000-0000-0000-0000-' || lpad(p.n::text, 12, '0'))::uuid,
       p.full_name, 'employee', true
  from hc_demo_people p;

-- Penilaian: self-assessment, review manajer tim, lalu kalibrasi oleh HC.
update performance_reviews pr
   set potential = p.potential,
       self_rating = p.self_rating,
       self_at = case when p.self_rating is not null then now() - interval '1 day' * (6 + p.n % 4) end,
       mgr_rating = p.mgr_rating,
       mgr_at = case when p.mgr_rating is not null then now() - interval '1 day' * (2 + p.n % 3) end,
       mgr_by = case when p.mgr_rating is not null
                     then (select id from workers m where m.team_id = p.team_id and m.role = 'manager' order by m.full_name limit 1) end,
       calib_rating = p.calib_rating,
       calib_at = case when p.calib_rating is not null then now() - interval '1 day' end,
       calib_by = case when p.calib_rating is not null
                       then (select id from workers h where h.tenant_id = '00000000-0000-0000-0000-000000000001'
                               and h.role = 'hc_admin' order by h.full_name limit 1) end
  from hc_demo_people p
 where pr.employee_id = ('62000000-0000-0000-0000-' || lpad(p.n::text, 12, '0'))::uuid
   and pr.cycle_id = 'd2000000-0000-0000-0000-000000000001';

-- Template rutin dijeda untuk outlet tanpa tugas rutin, sebagai induk riwayat SOP.
insert into recurring_templates (id, tenant_id, team_id, title, days_of_week, owner_id, checklist,
                                 priority_level, active, created_by, kind)
select ('e1000000-0000-0000-0000-' || lpad(x.k::text, 12, '0'))::uuid, '00000000-0000-0000-0000-000000000001', x.team_id,
       '{"id":"Checklist buka outlet","en":"Outlet opening checklist"}'::jsonb, '{1,2,3,4,5,6,7}'::smallint[],
       x.manager_id, '[]'::jsonb, 'NORMAL', false, x.manager_id, 'CHECKLIST'
  from (values
    (2, '30000000-0000-0000-0000-000000000002'::uuid, '60000000-0000-0000-0000-000000000007'::uuid),
    (3, '30000000-0000-0000-0000-000000000003'::uuid, '60000000-0000-0000-0000-000000000010'::uuid),
    (4, '30000000-0000-0000-0000-000000000004'::uuid, '60000000-0000-0000-0000-000000000013'::uuid)
  ) as x(k, team_id, manager_id);

-- Riwayat tugas rutin selesai (Juli sampai Agustus 2026) sebagai bukti kepatuhan SOP.
-- Satu instance per template per tanggal (unique template_id, occurrence_date).
with slots as (
  select p.n, p.team_id, gs.i,
         row_number() over (partition by p.team_id order by p.n, gs.i) as rn
    from hc_demo_people p
    cross join lateral generate_series(1, p.evidence) as gs(i)
),
tmpl as (
  select s.*,
         case when s.team_id = '30000000-0000-0000-0000-000000000001'
              then (array['e0000000-0000-0000-0000-000000000001','e0000000-0000-0000-0000-000000000002',
                          'e0000000-0000-0000-0000-000000000003','e0000000-0000-0000-0000-000000000004'])[1 + (s.rn % 4)]::uuid
              when s.team_id = '30000000-0000-0000-0000-000000000002' then 'e1000000-0000-0000-0000-000000000002'::uuid
              when s.team_id = '30000000-0000-0000-0000-000000000003' then 'e1000000-0000-0000-0000-000000000003'::uuid
              else 'e1000000-0000-0000-0000-000000000004'::uuid end as template_id,
         date '2026-07-01' + s.rn::integer as occ
    from slots s
)
insert into work_items (tenant_id, team_id, type, title, creator_id, owner_id, status, priority_level,
                        due_at, completed_at, template_id, occurrence_date)
select '00000000-0000-0000-0000-000000000001', t.team_id, 'RECURRING_WORK', rt.title, rt.created_by,
       ('62000000-0000-0000-0000-' || lpad(t.n::text, 12, '0'))::uuid, 'DONE', 'NORMAL',
       (t.occ + time '12:00') at time zone 'Asia/Jakarta',
       (t.occ + time '10:30') at time zone 'Asia/Jakarta',
       t.template_id, t.occ
  from tmpl t join recurring_templates rt on rt.id = t.template_id;

-- Weekly Check-in minggu ke-4 untuk enam prioritas (Cimahi waktu tunggu sengaja tidak).
insert into priority_checkins (tenant_id, priority_id, week_start, outcome_value, confidence, note, created_by, created_at, updated_at)
select '00000000-0000-0000-0000-000000000001', c.pid::uuid,
       (date_trunc('week', now() at time zone 'Asia/Jakarta'))::date - 28,
       c.v, c.conf, null, c.by::uuid,
       ((((date_trunc('week', now() at time zone 'Asia/Jakarta'))::date - 28) + 1) + time '09:00') at time zone 'Asia/Jakarta',
       ((((date_trunc('week', now() at time zone 'Asia/Jakarta'))::date - 28) + 1) + time '09:00') at time zone 'Asia/Jakarta'
  from (values
    ('80000000-0000-0000-0000-000000000001', 65.2, 'WATCH',    '60000000-0000-0000-0000-000000000004'),
    ('80000000-0000-0000-0000-000000000002', 92,   'ON_TRACK', '60000000-0000-0000-0000-000000000004'),
    ('81000000-0000-0000-0000-000000000003', 63,   'WATCH',    '60000000-0000-0000-0000-000000000007'),
    ('81000000-0000-0000-0000-000000000005', 131,  'ON_TRACK', '60000000-0000-0000-0000-000000000010'),
    ('81000000-0000-0000-0000-000000000006', 84,   'ON_TRACK', '60000000-0000-0000-0000-000000000010'),
    ('81000000-0000-0000-0000-000000000007', 58,   'ON_TRACK', '60000000-0000-0000-0000-000000000013')
  ) as c(pid, v, conf, by)
on conflict (priority_id, week_start) do nothing;

insert into demo_checkin_anchors (checkin_id, week_offset)
select c.id, 4
  from priority_checkins c
 where c.tenant_id = '00000000-0000-0000-0000-000000000001'
   and c.week_start = (date_trunc('week', now() at time zone 'Asia/Jakarta'))::date - 28
   and c.priority_id in ('80000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000002',
                         '81000000-0000-0000-0000-000000000003', '81000000-0000-0000-0000-000000000005',
                         '81000000-0000-0000-0000-000000000006', '81000000-0000-0000-0000-000000000007')
on conflict (checkin_id) do nothing;
