-- Multi-outlet dan ringkasan eksekutif.
--
-- Keputusan desain:
-- 1. Tiga outlet baru sebagai tim di unit bisnis yang sudah ada: Outlet Cimahi
--    (OTU · Cimahi), Outlet Buah Batu (OTS · Bandung Selatan), Outlet Cirebon
--    (OTS · Cirebon). Tiap outlet satu manajer dan dua karyawan dengan akun demo
--    (password sama dengan akun lain), Prioritas Utama dengan angka hasil bisnis
--    dan Action Plan, riwayat Weekly Check-in tiga minggu terakhir, dan tugas
--    dengan keadaan berbeda (selesai tepat waktu, terlambat, terkendala). Cimahi
--    sengaja tertinggal, Buah Batu campuran, Cirebon membaik, supaya dashboard
--    eksekutif punya perbandingan yang jujur. Outlet Dago ikut diberi riwayat
--    check-in tiga minggu.
-- 2. Dengan lebih dari satu tim, izin manajer dipersempit ke tim sendiri.
--    Sebelumnya cukup role manager untuk mengubah tugas siapa pun di tenant.
--    Helper can_manage_work_item(owner, team): pemilik, eksekutif/HC, atau
--    manajer tim tugas itu. Dipakai di policy work_items, checklist_items,
--    upload foto bukti, dan RPC complete_work_item, raise_blocker,
--    resolve_blocker. create_work_item menolak manajer yang menugaskan ke
--    anggota tim lain. Policy diubah dengan ALTER POLICY, fungsi dengan
--    CREATE OR REPLACE dengan tanda tangan yang sama.
-- 3. RPC executive_overview() untuk eksekutif dan HC: satu baris per tim
--    (entitas, unit bisnis, jumlah anggota, hitungan tugas, tindak lanjut audit
--    yang terbuka, audit terakhir, Prioritas Utama beserta Action Plan dan
--    riwayat check-in). Agregasi di server supaya browser tidak menarik semua
--    tugas tenant. Instance tugas rutin yang lebih tua dari kemarin tidak
--    dihitung, sama dengan jendela di aplikasi.
-- 4. Tidak ada DROP, REVOKE ALL, atau DELETE.

insert into teams (id, tenant_id, business_unit_id, name) values
  ('30000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', 'Outlet Cimahi'),
  ('30000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', 'Outlet Buah Batu'),
  ('30000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000004', 'Outlet Cirebon');

insert into positions (id, tenant_id, team_id, title) values
  ('40000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', 'Manajer outlet'),
  ('40000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', 'Shift lead'),
  ('40000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', 'Kasir'),
  ('40000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000003', 'Manajer outlet'),
  ('40000000-0000-0000-0000-000000000009', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000003', 'Barista senior'),
  ('40000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000003', 'Kasir'),
  ('40000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000004', 'Manajer outlet'),
  ('40000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000004', 'Shift lead'),
  ('40000000-0000-0000-0000-000000000013', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000004', 'Staf dapur');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at,
  raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at,
  confirmation_token, email_change, email_change_token_new, recovery_token
)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email,
       crypt('NusvaDemo2026!', gen_salt('bf')), now(), now(),
       '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', ''
  from (values
    ('50000000-0000-0000-0000-000000000007'::uuid, 'manajer.cimahi@demo.nusvapeople.local'),
    ('50000000-0000-0000-0000-000000000008'::uuid, 'andi@demo.nusvapeople.local'),
    ('50000000-0000-0000-0000-000000000009'::uuid, 'wulan@demo.nusvapeople.local'),
    ('50000000-0000-0000-0000-000000000010'::uuid, 'manajer.buahbatu@demo.nusvapeople.local'),
    ('50000000-0000-0000-0000-000000000011'::uuid, 'fajar@demo.nusvapeople.local'),
    ('50000000-0000-0000-0000-000000000012'::uuid, 'nina@demo.nusvapeople.local'),
    ('50000000-0000-0000-0000-000000000013'::uuid, 'manajer.cirebon@demo.nusvapeople.local'),
    ('50000000-0000-0000-0000-000000000014'::uuid, 'yusuf@demo.nusvapeople.local'),
    ('50000000-0000-0000-0000-000000000015'::uuid, 'lestari@demo.nusvapeople.local')
  ) as u(id, email);

insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), u.id, u.id::text, jsonb_build_object('sub', u.id::text, 'email', u.email), 'email', now(), now(), now()
  from auth.users u
 where u.id in ('50000000-0000-0000-0000-000000000007','50000000-0000-0000-0000-000000000008','50000000-0000-0000-0000-000000000009',
                '50000000-0000-0000-0000-000000000010','50000000-0000-0000-0000-000000000011','50000000-0000-0000-0000-000000000012',
                '50000000-0000-0000-0000-000000000013','50000000-0000-0000-0000-000000000014','50000000-0000-0000-0000-000000000015');

insert into workers (id, tenant_id, position_id, team_id, auth_user_id, full_name, role) values
  ('60000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000005', '30000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000007', 'Manajer Outlet Cimahi', 'manager'),
  ('60000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000006', '30000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000008', 'Andi', 'employee'),
  ('60000000-0000-0000-0000-000000000009', '00000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000007', '30000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000009', 'Wulan', 'employee'),
  ('60000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000008', '30000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000010', 'Manajer Outlet Buah Batu', 'manager'),
  ('60000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000009', '30000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000011', 'Fajar', 'employee'),
  ('60000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000010', '30000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000012', 'Nina', 'employee'),
  ('60000000-0000-0000-0000-000000000013', '00000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000011', '30000000-0000-0000-0000-000000000004', '50000000-0000-0000-0000-000000000013', 'Manajer Outlet Cirebon', 'manager'),
  ('60000000-0000-0000-0000-000000000014', '00000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000012', '30000000-0000-0000-0000-000000000004', '50000000-0000-0000-0000-000000000014', 'Yusuf', 'employee'),
  ('60000000-0000-0000-0000-000000000015', '00000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000013', '30000000-0000-0000-0000-000000000004', '50000000-0000-0000-0000-000000000015', 'Lestari', 'employee');

insert into business_outcomes (id, tenant_id, baseline, target, current_value, period, unit, label, reported_by, reported_at) values
  ('71000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001', 58, 75, 60, '2026-12-31', '%',
   '{"id":"Persentase hari outlet capai target harian","en":"Share of days the outlet hits its daily target"}', '60000000-0000-0000-0000-000000000007', now() - interval '6 days'),
  ('71000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000001', 9, 6, 8.1, '2026-11-30', 'menit',
   '{"id":"Rata-rata waktu tunggu pesanan","en":"Average order waiting time"}', '60000000-0000-0000-0000-000000000007', now() - interval '6 days'),
  ('71000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000001', 120, 200, 151, '2026-12-31', 'porsi',
   '{"id":"Porsi menu baru terjual per minggu","en":"New menu portions sold per week"}', '60000000-0000-0000-0000-000000000010', now() - interval '6 days'),
  ('71000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000001', 80, 92, 89, '2026-10-31', null,
   '{"id":"Skor audit higiene rata-rata","en":"Average hygiene audit score"}', '60000000-0000-0000-0000-000000000010', now() - interval '6 days'),
  ('71000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-000000000001', 55, 70, 66, '2026-12-31', '%',
   '{"id":"Persentase hari outlet capai target harian","en":"Share of days the outlet hits its daily target"}', '60000000-0000-0000-0000-000000000013', now() - interval '6 days');

insert into priorities (id, tenant_id, team_id, business_outcome_id, scope, status, statement, created_at) values
  ('81000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', '71000000-0000-0000-0000-000000000003', 'TEAM', 'AT_RISK',
   '{"id":"Outlet capai target harian: dari 58% ke 75% pada 31 Des 2026","en":"Outlet hits daily target: from 58% to 75% by 31 Dec 2026"}', '2026-09-01'),
  ('81000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', '71000000-0000-0000-0000-000000000004', 'TEAM', 'WATCH',
   '{"id":"Waktu tunggu pesanan: dari 9 ke 6 menit pada 30 Nov 2026","en":"Order waiting time: from 9 to 6 minutes by 30 Nov 2026"}', '2026-09-02'),
  ('81000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000003', '71000000-0000-0000-0000-000000000005', 'TEAM', 'WATCH',
   '{"id":"Penjualan menu baru: dari 120 ke 200 porsi per minggu pada 31 Des 2026","en":"New menu sales: from 120 to 200 portions a week by 31 Dec 2026"}', '2026-09-01'),
  ('81000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000003', '71000000-0000-0000-0000-000000000006', 'TEAM', 'ON_TRACK',
   '{"id":"Skor audit higiene: dari 80 ke 92 pada 31 Okt 2026","en":"Hygiene audit score: from 80 to 92 by 31 Oct 2026"}', '2026-09-02'),
  ('81000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000004', '71000000-0000-0000-0000-000000000007', 'TEAM', 'ON_TRACK',
   '{"id":"Outlet capai target harian: dari 55% ke 70% pada 31 Des 2026","en":"Outlet hits daily target: from 55% to 70% by 31 Dec 2026"}', '2026-09-01');

insert into drivers (id, tenant_id, priority_id, title, target, actual, unit) values
  ('91000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', '81000000-0000-0000-0000-000000000003',
   '{"id":"Tawarkan paket kopi susu di setiap transaksi","en":"Offer the coffee and milk bundle on every transaction"}', 600, 210, '{"id":"transaksi","en":"transactions"}'),
  ('91000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', '81000000-0000-0000-0000-000000000003',
   '{"id":"Briefing shift 10 menit","en":"10-minute shift briefing"}', 30, 9, '{"id":"sesi","en":"sessions"}'),
  ('91000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001', '81000000-0000-0000-0000-000000000004',
   '{"id":"Prep bahan sebelum jam sibuk","en":"Prep ingredients before the rush"}', 40, 18, '{"id":"hari","en":"days"}'),
  ('91000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000001', '81000000-0000-0000-0000-000000000005',
   '{"id":"Rekomendasikan menu baru ke pelanggan","en":"Recommend the new menu to customers"}', 400, 190, '{"id":"transaksi","en":"transactions"}'),
  ('91000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000001', '81000000-0000-0000-0000-000000000006',
   '{"id":"Checklist penutupan dapur terverifikasi","en":"Verified kitchen closing checklist"}', 60, 48, '{"id":"checklist","en":"checklists"}'),
  ('91000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000001', '81000000-0000-0000-0000-000000000007',
   '{"id":"Promosi jam sepi 14.00 sampai 16.00","en":"Quiet-hour promotion 14.00 to 16.00"}', 24, 15, '{"id":"hari","en":"days"}');

insert into priority_checkins (tenant_id, priority_id, week_start, outcome_value, confidence, note, created_by, created_at, updated_at)
select '00000000-0000-0000-0000-000000000001', c.pid::uuid,
       (date_trunc('week', now() at time zone 'Asia/Jakarta'))::date - 7 * c.w,
       c.v, c.conf, c.note, c.by::uuid,
       now() - interval '1 day' * (7 * c.w - 1), now() - interval '1 day' * (7 * c.w - 1)
  from (values
    ('80000000-0000-0000-0000-000000000001', 3, 66.0, 'WATCH', null, '60000000-0000-0000-0000-000000000004'),
    ('80000000-0000-0000-0000-000000000001', 2, 67.5, 'WATCH', null, '60000000-0000-0000-0000-000000000004'),
    ('80000000-0000-0000-0000-000000000001', 1, 68.4, 'WATCH', 'Penjualan sore masih di bawah target harian.', '60000000-0000-0000-0000-000000000004'),
    ('80000000-0000-0000-0000-000000000002', 3, 93, 'ON_TRACK', null, '60000000-0000-0000-0000-000000000004'),
    ('80000000-0000-0000-0000-000000000002', 2, 95, 'ON_TRACK', null, '60000000-0000-0000-0000-000000000004'),
    ('80000000-0000-0000-0000-000000000002', 1, 96, 'ON_TRACK', null, '60000000-0000-0000-0000-000000000004'),
    ('81000000-0000-0000-0000-000000000003', 3, 62, 'WATCH', null, '60000000-0000-0000-0000-000000000007'),
    ('81000000-0000-0000-0000-000000000003', 2, 61, 'WATCH', null, '60000000-0000-0000-0000-000000000007'),
    ('81000000-0000-0000-0000-000000000003', 1, 60, 'OFF_TRACK', 'Dua kasir baru, upsell belum jalan.', '60000000-0000-0000-0000-000000000007'),
    ('81000000-0000-0000-0000-000000000004', 3, 8.6, 'WATCH', null, '60000000-0000-0000-0000-000000000007'),
    ('81000000-0000-0000-0000-000000000004', 2, 8.3, 'WATCH', null, '60000000-0000-0000-0000-000000000007'),
    ('81000000-0000-0000-0000-000000000004', 1, 8.1, 'WATCH', null, '60000000-0000-0000-0000-000000000007'),
    ('81000000-0000-0000-0000-000000000005', 3, 138, 'ON_TRACK', null, '60000000-0000-0000-0000-000000000010'),
    ('81000000-0000-0000-0000-000000000005', 2, 146, 'WATCH', null, '60000000-0000-0000-0000-000000000010'),
    ('81000000-0000-0000-0000-000000000005', 1, 151, 'WATCH', 'Menu baru laku di jam makan siang saja.', '60000000-0000-0000-0000-000000000010'),
    ('81000000-0000-0000-0000-000000000006', 3, 85, 'ON_TRACK', null, '60000000-0000-0000-0000-000000000010'),
    ('81000000-0000-0000-0000-000000000006', 2, 87, 'ON_TRACK', null, '60000000-0000-0000-0000-000000000010'),
    ('81000000-0000-0000-0000-000000000006', 1, 89, 'ON_TRACK', null, '60000000-0000-0000-0000-000000000010'),
    ('81000000-0000-0000-0000-000000000007', 3, 60, 'ON_TRACK', null, '60000000-0000-0000-0000-000000000013'),
    ('81000000-0000-0000-0000-000000000007', 2, 63, 'ON_TRACK', null, '60000000-0000-0000-0000-000000000013'),
    ('81000000-0000-0000-0000-000000000007', 1, 66, 'ON_TRACK', 'Promosi jam sepi menaikkan transaksi sore.', '60000000-0000-0000-0000-000000000013')
  ) as c(pid, w, v, conf, note, by);

insert into work_items (id, tenant_id, team_id, type, title, creator_id, owner_id, status, priority_level,
                        due_at, completed_at, priority_id, driver_id, qty)
select w.id::uuid, '00000000-0000-0000-0000-000000000001', w.team::uuid, 'TASK', w.title::jsonb, w.creator::uuid, w.owner::uuid,
       w.status, w.prio,
       ((((now() at time zone 'Asia/Jakarta')::date) + w.due_day) + w.due_time) at time zone 'Asia/Jakarta',
       case when w.done_day is null then null
            else least(((((now() at time zone 'Asia/Jakarta')::date) + w.done_day) + time '14:00') at time zone 'Asia/Jakarta', now()) end,
       w.pid::uuid, w.did::uuid, 1
  from (values
    ('a1000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', '{"id":"Tawarkan paket kopi susu shift pagi","en":"Offer the coffee bundle on the morning shift"}',
     '60000000-0000-0000-0000-000000000007', '60000000-0000-0000-0000-000000000008', 'IN_PROGRESS', 'HIGH', 0, time '15:00', null::int,
     '81000000-0000-0000-0000-000000000003', '91000000-0000-0000-0000-000000000001'),
    ('a1000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000002', '{"id":"Briefing shift sore","en":"Evening shift briefing"}',
     '60000000-0000-0000-0000-000000000007', '60000000-0000-0000-0000-000000000009', 'READY', 'NORMAL', -1, time '15:00', null,
     '81000000-0000-0000-0000-000000000003', '91000000-0000-0000-0000-000000000002'),
    ('a1000000-0000-0000-0000-000000000003', '30000000-0000-0000-0000-000000000002', '{"id":"Perbaiki mesin espresso 2","en":"Repair espresso machine 2"}',
     '60000000-0000-0000-0000-000000000007', '60000000-0000-0000-0000-000000000007', 'BLOCKED', 'URGENT', -2, time '17:00', null,
     null, null),
    ('a1000000-0000-0000-0000-000000000004', '30000000-0000-0000-0000-000000000002', '{"id":"Rekap stok bahan mingguan","en":"Weekly ingredient stock recap"}',
     '60000000-0000-0000-0000-000000000007', '60000000-0000-0000-0000-000000000009', 'DONE', 'NORMAL', -1, time '17:00', -1,
     null, null),
    ('a1000000-0000-0000-0000-000000000005', '30000000-0000-0000-0000-000000000002', '{"id":"Prep bahan sebelum jam sibuk","en":"Prep ingredients before the rush"}',
     '60000000-0000-0000-0000-000000000007', '60000000-0000-0000-0000-000000000008', 'DONE', 'NORMAL', -3, time '10:00', -2,
     '81000000-0000-0000-0000-000000000004', '91000000-0000-0000-0000-000000000003'),
    ('a1000000-0000-0000-0000-000000000006', '30000000-0000-0000-0000-000000000003', '{"id":"Kenalkan menu baru ke 20 pelanggan","en":"Introduce the new menu to 20 customers"}',
     '60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000011', 'IN_PROGRESS', 'HIGH', 1, time '17:00', null,
     '81000000-0000-0000-0000-000000000005', '91000000-0000-0000-0000-000000000004'),
    ('a1000000-0000-0000-0000-000000000007', '30000000-0000-0000-0000-000000000003', '{"id":"Checklist penutupan dapur","en":"Kitchen closing checklist"}',
     '60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000012', 'DONE', 'NORMAL', -1, time '22:00', -1,
     '81000000-0000-0000-0000-000000000006', '91000000-0000-0000-0000-000000000005'),
    ('a1000000-0000-0000-0000-000000000008', '30000000-0000-0000-0000-000000000003', '{"id":"Kalibrasi grinder kopi","en":"Calibrate the coffee grinder"}',
     '60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000012', 'READY', 'NORMAL', 2, time '12:00', null,
     null, null),
    ('a1000000-0000-0000-0000-000000000009', '30000000-0000-0000-0000-000000000003', '{"id":"Foto display menu baru","en":"Photograph the new menu display"}',
     '60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000011', 'DONE', 'LOW', -2, time '17:00', -3,
     null, null),
    ('a1000000-0000-0000-0000-000000000010', '30000000-0000-0000-0000-000000000004', '{"id":"Promosi jam sepi hari ini","en":"Run the quiet-hour promotion today"}',
     '60000000-0000-0000-0000-000000000013', '60000000-0000-0000-0000-000000000014', 'IN_PROGRESS', 'HIGH', 0, time '16:00', null,
     '81000000-0000-0000-0000-000000000007', '91000000-0000-0000-0000-000000000006'),
    ('a1000000-0000-0000-0000-000000000011', '30000000-0000-0000-0000-000000000004', '{"id":"Rekap kas harian","en":"Daily cash recap"}',
     '60000000-0000-0000-0000-000000000013', '60000000-0000-0000-0000-000000000015', 'DONE', 'NORMAL', -1, time '22:00', -1,
     null, null),
    ('a1000000-0000-0000-0000-000000000012', '30000000-0000-0000-0000-000000000004', '{"id":"Cek suhu chiller pagi","en":"Morning chiller temperature check"}',
     '60000000-0000-0000-0000-000000000013', '60000000-0000-0000-0000-000000000015', 'DONE', 'HIGH', 0, time '18:00', 0,
     null, null),
    ('a1000000-0000-0000-0000-000000000013', '30000000-0000-0000-0000-000000000004', '{"id":"Pasang banner promo","en":"Put up the promo banner"}',
     '60000000-0000-0000-0000-000000000013', '60000000-0000-0000-0000-000000000014', 'READY', 'LOW', 3, time '17:00', null,
     null, null)
  ) as w(id, team, title, creator, owner, status, prio, due_day, due_time, done_day, pid, did);

insert into blockers (tenant_id, work_item_id, reason, raised_by, status)
values ('00000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000003',
        'Menunggu teknisi vendor, jadwal paling cepat lusa.', '60000000-0000-0000-0000-000000000007', 'OPEN');

update performance_reviews r
   set potential = s.pot, self_rating = s.sr, self_note = s.sn, self_at = case when s.sr is null then null else now() - interval '2 days' end,
       mgr_rating = s.mr, mgr_note = s.mn, mgr_at = case when s.mr is null then null else now() - interval '1 day' end, mgr_by = s.mby::uuid
  from (values
    ('60000000-0000-0000-0000-000000000008', 1, 1, 'Upsell pagi belum konsisten, perlu latihan bareng.', null::int, null, null),
    ('60000000-0000-0000-0000-000000000009', 1, null, null, null, null, null),
    ('60000000-0000-0000-0000-000000000011', 2, 2, 'Penjualan menu baru naik di shift saya.', 2, 'Inisiatif bagus, lanjutkan ke shift sore.', '60000000-0000-0000-0000-000000000010'),
    ('60000000-0000-0000-0000-000000000012', 1, 1, 'Checklist penutupan selalu lengkap.', null, null, null),
    ('60000000-0000-0000-0000-000000000014', 2, null, null, null, null, null),
    ('60000000-0000-0000-0000-000000000015', 1, 1, 'Rekap kas dan cek chiller tepat waktu.', 1, 'Konsisten.', '60000000-0000-0000-0000-000000000013')
  ) as s(wid, pot, sr, sn, mr, mn, mby)
 where r.employee_id = s.wid::uuid and r.cycle_id = 'd2000000-0000-0000-0000-000000000001';

create or replace function can_manage_work_item(p_owner uuid, p_team uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_owner = current_worker_id()
      or current_worker_role() in ('executive','hc_admin')
      or (current_worker_role() = 'manager'
          and p_team = (select team_id from workers where id = current_worker_id()));
$$;

alter policy work_items_write on work_items
  using (tenant_id = current_tenant_id() and can_manage_work_item(owner_id, team_id))
  with check (tenant_id = current_tenant_id() and can_manage_work_item(owner_id, team_id));

alter policy checklist_items_write on checklist_items
  using (tenant_id = current_tenant_id() and exists (
    select 1 from work_items w where w.id = checklist_items.work_item_id and can_manage_work_item(w.owner_id, w.team_id)))
  with check (tenant_id = current_tenant_id() and exists (
    select 1 from work_items w where w.id = checklist_items.work_item_id and can_manage_work_item(w.owner_id, w.team_id)));

alter policy evidence_photos_insert on storage.objects
  with check (
    bucket_id = 'evidence-photos'
    and (storage.foldername(name))[1] = public.current_tenant_id()::text
    and exists (
      select 1 from public.work_items w
       where w.id::text = (storage.foldername(name))[2]
         and w.tenant_id = public.current_tenant_id()
         and public.can_manage_work_item(w.owner_id, w.team_id)
    )
  );

create or replace function complete_work_item(p_work_item_id uuid)
returns work_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item work_items;
  v_actor uuid := current_worker_id();
begin
  select * into v_item from work_items
    where id = p_work_item_id and tenant_id = current_tenant_id();
  if v_item.id is null then
    raise exception 'work item not found';
  end if;
  if not can_manage_work_item(v_item.owner_id, v_item.team_id) then
    raise exception 'not authorized to complete this work item';
  end if;

  if v_item.requires_approval and v_item.status <> 'DONE'
     and v_item.approval_status is distinct from 'APPROVED' then
    if v_item.approval_status = 'PENDING' then
      raise exception 'already waiting for approval';
    end if;
    perform assert_work_item_completable(v_item);
    perform set_config('nusva.approval_rpc', 'on', true);
    update work_items
       set status = 'WAITING', approval_status = 'PENDING', approved_by = null, approved_at = null
     where id = p_work_item_id
    returning * into v_item;
    perform set_config('nusva.approval_rpc', 'off', true);
    insert into work_item_comments (tenant_id, work_item_id, author_id, kind)
    values (v_item.tenant_id, v_item.id, v_actor, 'SUBMITTED');
    return v_item;
  end if;

  update work_items set status = 'DONE'
    where id = p_work_item_id
    returning * into v_item;

  insert into evidence (tenant_id, work_item_id, type, payload, created_by)
  values (v_item.tenant_id, v_item.id, 'SYSTEM_EVENT',
          jsonb_build_object('event', 'work_item_completed', 'at', now()), v_actor);

  if v_item.driver_id is not null and v_item.qty is not null then
    update drivers set actual = actual + v_item.qty, version = version + 1
      where id = v_item.driver_id;
  end if;

  return v_item;
end;
$$;

create or replace function raise_blocker(p_work_item_id uuid, p_reason text)
returns blockers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item work_items;
  v_actor uuid := current_worker_id();
  v_blocker blockers;
begin
  select * into v_item from work_items
    where id = p_work_item_id and tenant_id = current_tenant_id();
  if v_item.id is null then
    raise exception 'work item not found';
  end if;
  if not can_manage_work_item(v_item.owner_id, v_item.team_id) then
    raise exception 'not authorized to raise a blocker on this work item';
  end if;

  update work_items set status = 'BLOCKED' where id = p_work_item_id;

  insert into blockers (tenant_id, work_item_id, reason, raised_by, status)
  values (v_item.tenant_id, p_work_item_id, p_reason, v_actor, 'OPEN')
  returning * into v_blocker;

  return v_blocker;
end;
$$;

create or replace function resolve_blocker(p_blocker_id uuid)
returns blockers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_blocker blockers;
  v_item work_items;
  v_open_remaining int;
begin
  select * into v_blocker from blockers
    where id = p_blocker_id and tenant_id = current_tenant_id();
  if v_blocker.id is null then
    raise exception 'blocker not found';
  end if;

  select * into v_item from work_items where id = v_blocker.work_item_id;
  if not can_manage_work_item(v_item.owner_id, v_item.team_id) then
    raise exception 'not authorized to resolve this blocker';
  end if;

  update blockers set status = 'RESOLVED', resolved_at = now()
    where id = p_blocker_id
    returning * into v_blocker;

  select count(*) into v_open_remaining from blockers
    where work_item_id = v_item.id and status = 'OPEN';

  if v_open_remaining = 0 and v_item.status = 'BLOCKED' then
    update work_items set status = 'READY' where id = v_item.id;
  end if;

  return v_blocker;
end;
$$;

create or replace function create_work_item(p_title_id text, p_title_en text, p_due_at timestamptz,
                                            p_priority_level text default 'NORMAL', p_owner_id uuid default null)
returns work_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_role text := current_worker_role();
  v_tenant uuid := current_tenant_id();
  v_owner uuid := coalesce(p_owner_id, v_actor);
  v_team uuid;
  v_item work_items;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  if p_title_id is null or btrim(p_title_id) = '' then
    raise exception 'title is required';
  end if;
  if p_due_at is null then
    raise exception 'due date is required';
  end if;
  if p_owner_id is not null and p_owner_id <> v_actor and v_role not in ('manager','executive','hc_admin') then
    raise exception 'not authorized to assign work to another worker';
  end if;

  select team_id into v_team from workers where id = v_owner and tenant_id = v_tenant;
  if v_team is null then
    raise exception 'owner has no team to create this work item in';
  end if;
  if v_owner <> v_actor and v_role = 'manager'
     and v_team is distinct from (select team_id from workers where id = v_actor) then
    raise exception 'not authorized to assign work to another team';
  end if;

  insert into work_items (tenant_id, team_id, type, title, creator_id, owner_id, status, priority_level, due_at)
  values (
    v_tenant, v_team, 'TASK',
    jsonb_build_object('id', p_title_id, 'en', coalesce(nullif(btrim(p_title_en), ''), p_title_id)),
    v_actor, v_owner, 'READY', p_priority_level, p_due_at
  )
  returning * into v_item;

  return v_item;
end;
$$;

create or replace function executive_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_tenant uuid := current_tenant_id();
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_teams jsonb;
begin
  if current_worker_role() not in ('executive','hc_admin') then
    raise exception 'not authorized to view the executive overview';
  end if;

  select coalesce(jsonb_agg(row_to_json(x)::jsonb order by x.entity_code, x.name), '[]'::jsonb) into v_teams
    from (
      select t.id, t.name, bu.name as business_unit, le.code as entity_code, le.name as entity_name,
             (select count(*) from workers w where w.team_id = t.id) as headcount,
             (select jsonb_build_object(
                'active', count(*) filter (where wi.status not in ('DONE','CANCELLED')),
                'overdue', count(*) filter (where wi.status not in ('DONE','CANCELLED') and wi.due_at < now()),
                'blocked', count(*) filter (where wi.status = 'BLOCKED'),
                'waiting_approval', count(*) filter (where wi.approval_status = 'PENDING'),
                'active_prio', count(*) filter (where wi.status not in ('DONE','CANCELLED') and wi.driver_id is not null),
                'done_7d', count(*) filter (where wi.status = 'DONE' and wi.completed_at >= now() - interval '7 days'),
                'done_7d_ontime', count(*) filter (where wi.status = 'DONE' and wi.completed_at >= now() - interval '7 days'
                                                    and (wi.due_at is null or wi.completed_at <= wi.due_at)),
                'followups_open', count(*) filter (where wi.parent_work_id is not null and wi.status not in ('DONE','CANCELLED')))
                from work_items wi
               where wi.team_id = t.id
                 and not (wi.template_id is not null and wi.occurrence_date < v_today - 1)) as tasks,
             (select jsonb_build_object('at', a.completed_at,
                       'pass', (select count(*) from checklist_items c where c.work_item_id = a.id and c.result = 'PASS'),
                       'total', (select count(*) from checklist_items c where c.work_item_id = a.id))
                from work_items a join recurring_templates rt on rt.id = a.template_id
               where a.team_id = t.id and rt.kind = 'AUDIT' and a.status = 'DONE'
               order by a.completed_at desc nulls last limit 1) as audit_last,
             (select coalesce(jsonb_agg(jsonb_build_object(
                       'id', p.id, 'statement', p.statement, 'status', p.status,
                       'label', bo.label, 'baseline', bo.baseline, 'target', bo.target, 'current', bo.current_value,
                       'unit', bo.unit, 'reported_at', bo.reported_at,
                       'reported_by', (select full_name from workers where id = bo.reported_by),
                       'drivers', (select coalesce(jsonb_agg(jsonb_build_object('title', d.title, 'target', d.target,
                                                    'actual', d.actual, 'unit', d.unit) order by d.title->>'id'), '[]'::jsonb)
                                     from drivers d where d.priority_id = p.id),
                       'checkins', (select coalesce(jsonb_agg(jsonb_build_object('week_start', c.week_start, 'value', c.outcome_value,
                                                    'confidence', c.confidence, 'note', c.note,
                                                    'by', (select full_name from workers where id = c.created_by)) order by c.week_start), '[]'::jsonb)
                                      from (select * from priority_checkins pc where pc.priority_id = p.id
                                             order by pc.week_start desc limit 6) c)
                     ) order by p.created_at), '[]'::jsonb)
                from priorities p left join business_outcomes bo on bo.id = p.business_outcome_id
               where p.team_id = t.id and p.status not in ('CLOSED','CANCELLED')) as priorities
        from teams t
        join business_units bu on bu.id = t.business_unit_id
        join legal_entities le on le.id = bu.legal_entity_id
       where t.tenant_id = v_tenant
    ) x;

  return jsonb_build_object('as_of', now(), 'today', v_today,
                            'week_start', (date_trunc('week', now() at time zone 'Asia/Jakarta'))::date,
                            'teams', v_teams);
end;
$$;

revoke execute on function can_manage_work_item(uuid, uuid) from public, anon;
revoke execute on function executive_overview() from public, anon;
grant execute on function can_manage_work_item(uuid, uuid) to authenticated;
grant execute on function executive_overview() to authenticated;
