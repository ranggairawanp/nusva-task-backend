-- Job harian yang menjaga deadline tugas demo tetap segar (disetujui pemilik produk).
--
-- Data demo itu diam, jadi tanpa ini semua tugas seed (009, 023) mulai tercatat terlambat
-- sehari setelah dibuat ulang, seperti yang sudah dua kali dirapikan manual (012, 024).
--
-- Keputusan desain:
-- 1. demo_task_anchors menyimpan posisi tiap tugas demo relatif terhadap hari ini: offset hari
--    dan jam deadline, serta (khusus tugas yang sudah selesai) offset hari dan jam selesainya.
--    Pola yang sama dengan seed asli: ada yang hari ini, besok, kemarin (terlambat), dan
--    selesai tepat waktu atau terlambat. Tugas demo baru cukup ditambah barisnya.
-- 2. refresh_demo_deadlines() hanya mengubah due_at dan completed_at tugas yang terdaftar di
--    tabel itu. Status tidak pernah diubah, jadi tugas yang diselesaikan orang saat demo tetap
--    selesai. completed_at dibatasi now() supaya tidak pernah di masa depan. Tugas rutin tidak
--    terdaftar dan tidak disentuh.
-- 3. pg_cron menjalankannya setiap hari 22.01 UTC (05.01 WIB). Fungsi tidak bisa dipanggil
--    dari aplikasi (execute dicabut dari public, anon, authenticated); tabelnya RLS aktif tanpa
--    policy, jadi tidak terbaca dari aplikasi. Untuk menghentikan: select cron.unschedule(
--    'nusva-demo-deadlines');
-- 4. Tidak ada DROP, REVOKE ALL, atau DELETE.

create table demo_task_anchors (
  work_item_id uuid primary key references work_items(id) on delete cascade,
  due_day integer not null,
  due_time time not null,
  done_day integer,
  done_time time,
  check ((done_day is null) = (done_time is null))
);
alter table demo_task_anchors enable row level security;

insert into demo_task_anchors (work_item_id, due_day, due_time, done_day, done_time) values
  ('a0000000-0000-0000-0000-000000000001',  0, '17:00', null, null),
  ('a0000000-0000-0000-0000-000000000002',  0, '17:00', null, null),
  ('a0000000-0000-0000-0000-000000000007',  0, '17:00', null, null),
  ('a0000000-0000-0000-0000-000000000004',  1, '17:00', null, null),
  ('a0000000-0000-0000-0000-000000000006',  1, '17:00', null, null),
  ('a0000000-0000-0000-0000-000000000010',  1, '17:00', null, null),
  ('a0000000-0000-0000-0000-000000000009', -1, '17:00', null, null),
  ('a0000000-0000-0000-0000-000000000003',  0, '17:00',    0, '10:00'),
  ('a0000000-0000-0000-0000-000000000005',  0, '17:00',    0, '10:00'),
  ('a0000000-0000-0000-0000-000000000008',  0, '17:00',    0, '10:00'),
  ('a1000000-0000-0000-0000-000000000001',  0, '15:00', null, null),
  ('a1000000-0000-0000-0000-000000000002', -1, '15:00', null, null),
  ('a1000000-0000-0000-0000-000000000003', -2, '17:00', null, null),
  ('a1000000-0000-0000-0000-000000000004', -1, '17:00',   -1, '14:00'),
  ('a1000000-0000-0000-0000-000000000005', -3, '10:00',   -2, '14:00'),
  ('a1000000-0000-0000-0000-000000000006',  1, '17:00', null, null),
  ('a1000000-0000-0000-0000-000000000007', -1, '22:00',   -1, '14:00'),
  ('a1000000-0000-0000-0000-000000000008',  2, '12:00', null, null),
  ('a1000000-0000-0000-0000-000000000009', -2, '17:00',   -3, '14:00'),
  ('a1000000-0000-0000-0000-000000000010',  0, '16:00', null, null),
  ('a1000000-0000-0000-0000-000000000011', -1, '22:00',   -1, '14:00'),
  ('a1000000-0000-0000-0000-000000000012',  0, '18:00',    0, '14:00'),
  ('a1000000-0000-0000-0000-000000000013',  3, '17:00', null, null)
on conflict (work_item_id) do nothing;

create or replace function refresh_demo_deadlines()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_count integer;
begin
  update work_items w
     set due_at = ((v_today + a.due_day) + a.due_time) at time zone 'Asia/Jakarta',
         completed_at = case
           when w.status = 'DONE' and a.done_day is not null
             then least(now(), ((v_today + a.done_day) + a.done_time) at time zone 'Asia/Jakarta')
           else w.completed_at end
    from demo_task_anchors a
   where w.id = a.work_item_id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function refresh_demo_deadlines() from public, anon, authenticated;

create extension if not exists pg_cron;

select cron.schedule('nusva-demo-deadlines', '1 22 * * *', 'select public.refresh_demo_deadlines()');

select refresh_demo_deadlines();
