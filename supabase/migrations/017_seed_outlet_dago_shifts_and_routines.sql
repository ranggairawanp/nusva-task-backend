-- Seed demo untuk migration 016: dua shift Outlet Dago, lima template tugas
-- rutin, dan satu catatan serah terima dari shift sore kemarin.
--
-- Yang disintesis (tidak ada di data.js): jam shift (07.00-15.00 dan
-- 15.00-23.00, pola umum outlet F&B dua shift), isi checklist, dan isi
-- catatan serah terima. Penanggung jawab mengikuti posisi di seed 009:
-- Rina shift lead, Dedi kasir, Sari inspeksi dan higiene, plus manajer.
-- Instance harian tidak di-seed: dibuat generate_routine_work() saat
-- frontend pertama kali memuat daftar tugas.

insert into shifts (id, tenant_id, team_id, code, name, starts_at, ends_at, position) values
  ('d0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001',
   'pagi', '{"id":"Pagi","en":"Morning"}', '07:00', '15:00', 1),
  ('d0000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001',
   'sore', '{"id":"Sore","en":"Evening"}', '15:00', '23:00', 2);

insert into recurring_templates (id, tenant_id, team_id, title, shift_id, days_of_week, owner_id, checklist, priority_level, created_by) values
  ('e0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001',
   '{"id":"Checklist buka outlet","en":"Outlet opening checklist"}', 'd0000000-0000-0000-0000-000000000001', '{1,2,3,4,5,6,7}',
   '60000000-0000-0000-0000-000000000002',
   '[{"id":"Lampu dan AC menyala","en":"Lights and AC on"},{"id":"Mesin kasir siap","en":"Cash register ready"},{"id":"Etalase terisi","en":"Display case stocked"}]',
   'HIGH', '60000000-0000-0000-0000-000000000004'),
  ('e0000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001',
   '{"id":"Cek suhu chiller dan freezer","en":"Chiller and freezer temperature check"}', 'd0000000-0000-0000-0000-000000000001', '{1,2,3,4,5,6,7}',
   '60000000-0000-0000-0000-000000000001',
   '[{"id":"Chiller 1 di bawah 5°C","en":"Chiller 1 below 5°C"},{"id":"Chiller 2 di bawah 5°C","en":"Chiller 2 below 5°C"},{"id":"Freezer di bawah -18°C","en":"Freezer below -18°C"}]',
   'HIGH', '60000000-0000-0000-0000-000000000004'),
  ('e0000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001',
   '{"id":"Checklist tutup outlet","en":"Outlet closing checklist"}', 'd0000000-0000-0000-0000-000000000002', '{1,2,3,4,5,6,7}',
   '60000000-0000-0000-0000-000000000003',
   '[{"id":"Dapur dibersihkan","en":"Kitchen cleaned"},{"id":"Peralatan dimatikan","en":"Equipment switched off"},{"id":"Gudang dikunci","en":"Storeroom locked"}]',
   'HIGH', '60000000-0000-0000-0000-000000000004'),
  ('e0000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001',
   '{"id":"Rekap kas shift sore","en":"Evening shift cash reconciliation"}', 'd0000000-0000-0000-0000-000000000002', '{1,2,3,4,5,6,7}',
   '60000000-0000-0000-0000-000000000004', '[]', 'NORMAL', '60000000-0000-0000-0000-000000000004'),
  ('e0000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001',
   '{"id":"Inspeksi higiene area dapur","en":"Kitchen hygiene inspection"}', 'd0000000-0000-0000-0000-000000000001', '{1,4}',
   '60000000-0000-0000-0000-000000000003',
   '[{"id":"Lantai dan saluran air","en":"Floor and drains"},{"id":"Tanggal kedaluwarsa bahan","en":"Ingredient expiry dates"}]',
   'NORMAL', '60000000-0000-0000-0000-000000000004');

insert into shift_handovers (id, tenant_id, team_id, shift_id, handover_date, author_id, note, created_at) values
  ('f0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001',
   'd0000000-0000-0000-0000-000000000002', (now() at time zone 'Asia/Jakarta')::date - 1, '60000000-0000-0000-0000-000000000003',
   'Freezer berbunyi keras sejak jam 20.00, sudah dilaporkan ke teknisi. Stok susu tinggal 6 liter, perlu dipesan pagi ini.',
   (((now() at time zone 'Asia/Jakarta')::date - 1) + time '22:45') at time zone 'Asia/Jakarta');
