-- Geser ulang deadline tugas demo Outlet Dago ke sekitar tanggal migration ini diterapkan.
--
-- Migration 012 menjangkarkan tugas seed 009 ke 21 sampai 24 September 2026. Sejak itu semua
-- tugas yang belum selesai tercatat terlambat, sehingga di dashboard eksekutif (migration 023)
-- Outlet Dago tampak jauh lebih buruk daripada outlet lain yang seed-nya baru. Pola hubungan
-- harinya sama seperti seed asli: tiga tugas hari ini, tiga besok, satu terlambat (kemarin),
-- semua 17.00 WIB. Tiga tugas yang sudah DONE ikut digeser dan diberi completed_at hari ini
-- sebelum deadline, supaya terhitung selesai tepat waktu. Tugas rutin (template_id terisi)
-- tidak disentuh karena dibuat otomatis oleh generate_routine_work.
--
-- Seperti 012, ini perapian data demo sekali jalan, bukan sesuatu yang dibutuhkan sistem nyata.
-- Tidak ada DROP, REVOKE ALL, atau DELETE.

update work_items
   set due_at = ((((now() at time zone 'Asia/Jakarta')::date) + d.day_offset) + time '17:00') at time zone 'Asia/Jakarta'
  from (values
    ('a0000000-0000-0000-0000-000000000001'::uuid, 0),
    ('a0000000-0000-0000-0000-000000000002'::uuid, 0),
    ('a0000000-0000-0000-0000-000000000007'::uuid, 0),
    ('a0000000-0000-0000-0000-000000000004'::uuid, 1),
    ('a0000000-0000-0000-0000-000000000006'::uuid, 1),
    ('a0000000-0000-0000-0000-000000000010'::uuid, 1),
    ('a0000000-0000-0000-0000-000000000009'::uuid, -1)
  ) as d(id, day_offset)
 where work_items.id = d.id and work_items.status <> 'DONE';

update work_items
   set due_at = (((now() at time zone 'Asia/Jakarta')::date) + time '17:00') at time zone 'Asia/Jakarta',
       completed_at = least(now(), (((now() at time zone 'Asia/Jakarta')::date) + time '10:00') at time zone 'Asia/Jakarta')
 where id in ('a0000000-0000-0000-0000-000000000003',
              'a0000000-0000-0000-0000-000000000005',
              'a0000000-0000-0000-0000-000000000008')
   and status = 'DONE';
