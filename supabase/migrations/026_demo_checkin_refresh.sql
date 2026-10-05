-- Perluas job harian demo (025) supaya riwayat Weekly Check-in demo ikut segar.
--
-- Tanpa ini, check-in seed (023) makin tua setiap minggu: tren 4 minggu di dashboard eksekutif
-- jadi datar dan riwayat check-in di Progres menunjuk minggu-minggu lama.
--
-- Keputusan desain:
-- 1. demo_checkin_anchors mencatat check-in demo dan posisinya: 1, 2, atau 3 minggu sebelum
--    minggu berjalan (Senin, Asia/Jakarta). Minggu berjalan sengaja dibiarkan kosong supaya
--    manajer di demo bisa mengisi Weekly Check-in sendiri.
-- 2. refresh_demo_deadlines() (dipanggil job nusva-demo-deadlines, 05.01 WIB) sekarang juga
--    menggeser week_start, created_at, dan updated_at check-in demo, serta reported_at angka
--    hasil bisnis prioritasnya ke tanggal check-in demo terakhir.
-- 3. Data nyata menang: prioritas yang sudah punya satu saja check-in di luar daftar demo
--    (diisi manajer lewat aplikasi) tidak digeser lagi, check-in demonya dibiarkan apa adanya.
--    Ini juga mencegah bentrok unique (priority_id, week_start).
-- 4. Pergeseran dua langkah: check-in yang akan digeser dipindah dulu ke minggu penampung
--    (1900, berbeda per posisi) lalu ke minggu tujuan, supaya unique tidak bentrok di tengah
--    UPDATE. Satu transaksi (satu panggilan fungsi), jadi minggu penampung tidak pernah
--    terlihat dari luar.
-- 5. Tidak ada DROP, REVOKE ALL, atau DELETE.

create table demo_checkin_anchors (
  checkin_id uuid primary key references priority_checkins(id) on delete cascade,
  week_offset integer not null check (week_offset between 1 and 26)
);
alter table demo_checkin_anchors enable row level security;

insert into demo_checkin_anchors (checkin_id, week_offset)
select c.id, ((date_trunc('week', now() at time zone 'Asia/Jakarta'))::date - c.week_start) / 7
  from priority_checkins c
 where c.tenant_id = '00000000-0000-0000-0000-000000000001'
   and c.priority_id in ('80000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000002',
                         '81000000-0000-0000-0000-000000000003', '81000000-0000-0000-0000-000000000004',
                         '81000000-0000-0000-0000-000000000005', '81000000-0000-0000-0000-000000000006',
                         '81000000-0000-0000-0000-000000000007')
   and c.week_start < (date_trunc('week', now() at time zone 'Asia/Jakarta'))::date
   and ((date_trunc('week', now() at time zone 'Asia/Jakarta'))::date - c.week_start) / 7 between 1 and 26
on conflict (checkin_id) do nothing;

create or replace function refresh_demo_deadlines()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_monday date := (date_trunc('week', now() at time zone 'Asia/Jakarta'))::date;
  v_tasks integer;
  v_checkins integer;
begin
  update work_items w
     set due_at = ((v_today + a.due_day) + a.due_time) at time zone 'Asia/Jakarta',
         completed_at = case
           when w.status = 'DONE' and a.done_day is not null
             then least(now(), ((v_today + a.done_day) + a.done_time) at time zone 'Asia/Jakarta')
           else w.completed_at end
    from demo_task_anchors a
   where w.id = a.work_item_id;
  get diagnostics v_tasks = row_count;

  update priority_checkins c
     set week_start = date '1900-01-01' + 7 * a.week_offset
    from demo_checkin_anchors a
   where a.checkin_id = c.id
     and not exists (
       select 1 from priority_checkins x
        where x.priority_id = c.priority_id
          and not exists (select 1 from demo_checkin_anchors b where b.checkin_id = x.id));

  update priority_checkins c
     set week_start = v_monday - 7 * a.week_offset,
         created_at = least(now(), (((v_monday - 7 * a.week_offset) + 1) + time '09:00') at time zone 'Asia/Jakarta'),
         updated_at = least(now(), (((v_monday - 7 * a.week_offset) + 1) + time '09:00') at time zone 'Asia/Jakarta')
    from demo_checkin_anchors a
   where a.checkin_id = c.id
     and not exists (
       select 1 from priority_checkins x
        where x.priority_id = c.priority_id
          and not exists (select 1 from demo_checkin_anchors b where b.checkin_id = x.id));
  get diagnostics v_checkins = row_count;

  update business_outcomes bo
     set reported_at = least(now(), (((v_monday - 7 * x.min_offset) + 1) + time '09:00') at time zone 'Asia/Jakarta')
    from (select p.business_outcome_id, min(a.week_offset) as min_offset
            from priority_checkins c
            join demo_checkin_anchors a on a.checkin_id = c.id
            join priorities p on p.id = c.priority_id
           where p.business_outcome_id is not null
             and not exists (
               select 1 from priority_checkins x
                where x.priority_id = c.priority_id
                  and not exists (select 1 from demo_checkin_anchors b where b.checkin_id = x.id))
           group by p.business_outcome_id) x
   where bo.id = x.business_outcome_id;

  return v_tasks + v_checkins;
end;
$$;

revoke execute on function refresh_demo_deadlines() from public, anon, authenticated;

select refresh_demo_deadlines();
