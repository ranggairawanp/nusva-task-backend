-- Siklus penilaian: self-assessment, review manajer, dan kalibrasi.
--
-- Keputusan desain:
-- 1. review_cycles menyimpan nama siklus dan tiga deadline (self-assessment,
--    review manajer, kalibrasi). Tahap siklus tidak disimpan: aplikasi
--    menurunkannya dari tanggal hari ini terhadap deadline, jadi tidak ada
--    kolom yang bisa basi.
-- 2. performance_reviews satu baris per karyawan per siklus. Rating 0 sampai 3
--    (Perlu perbaikan, Sesuai harapan, Di atas harapan, Luar biasa), sama
--    dengan skala r_l1..r_l4 di aplikasi. Setiap rating menyimpan pengisi dan
--    waktunya, karena setiap angka wajib menyebut asalnya.
-- 3. Baca dibatasi, bukan seluas tenant: karyawan hanya melihat barisnya
--    sendiri, manajer melihat anggota timnya, eksekutif dan HC melihat semua
--    di tenant. Penilaian adalah data pribadi, tidak ada peringkat.
-- 4. Tulis hanya lewat RPC (tabel tidak punya policy tulis):
--    submit_self_assessment oleh karyawan itu sendiri sebelum review manajer
--    masuk; submit_manager_review oleh manajer tim (atau eksekutif/HC), bukan
--    untuk dirinya sendiri, dan hanya setelah self-assessment terisi;
--    calibrate_review menetapkan rating akhir setelah review manajer.
--    Semua menolak siklus yang sudah ditutup.
-- 5. Karyawan baru otomatis mendapat baris di siklus yang masih terbuka
--    (trigger di workers), supaya anggota tim yang ditambah dari aplikasi
--    langsung ikut siklus.
-- 6. Tidak ada DROP, REVOKE ALL, atau DELETE.

create table review_cycles (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  name jsonb not null,
  starts_on date not null,
  ends_on date not null,
  due_self date not null,
  due_mgr date not null,
  due_calib date not null,
  status text not null default 'OPEN' check (status in ('OPEN','CLOSED')),
  created_at timestamptz not null default now(),
  check (due_self <= due_mgr and due_mgr <= due_calib)
);
create index review_cycles_tenant_idx on review_cycles (tenant_id, starts_on desc);
alter table review_cycles enable row level security;
grant select on review_cycles to authenticated;
create policy tenant_isolation_select on review_cycles for select
  using (tenant_id = current_tenant_id());

create table performance_reviews (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  cycle_id uuid not null references review_cycles(id) on delete cascade,
  employee_id uuid not null references workers(id),
  potential smallint check (potential between 0 and 2),
  self_rating smallint check (self_rating between 0 and 3),
  self_note text check (self_note is null or char_length(self_note) <= 1000),
  self_at timestamptz,
  mgr_rating smallint check (mgr_rating between 0 and 3),
  mgr_note text check (mgr_note is null or char_length(mgr_note) <= 1000),
  mgr_at timestamptz,
  mgr_by uuid references workers(id),
  calib_rating smallint check (calib_rating between 0 and 3),
  calib_note text check (calib_note is null or char_length(calib_note) <= 1000),
  calib_at timestamptz,
  calib_by uuid references workers(id),
  unique (cycle_id, employee_id),
  check (mgr_rating is null or self_rating is not null),
  check (calib_rating is null or mgr_rating is not null)
);
create index performance_reviews_employee_idx on performance_reviews (employee_id);
alter table performance_reviews enable row level security;
grant select on performance_reviews to authenticated;
create policy performance_reviews_select on performance_reviews for select
  using (
    tenant_id = current_tenant_id()
    and (
      employee_id = current_worker_id()
      or current_worker_role() in ('executive','hc_admin')
      or (current_worker_role() = 'manager'
          and (select team_id from workers where id = employee_id)
            = (select team_id from workers where id = current_worker_id()))
    )
  );

create or replace function can_review_worker(p_employee uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select current_worker_role() in ('executive','hc_admin')
      or (current_worker_role() = 'manager'
          and (select team_id from workers where id = p_employee and tenant_id = current_tenant_id())
            = (select team_id from workers where id = current_worker_id()));
$$;

create or replace function submit_self_assessment(p_review_id uuid, p_rating integer, p_note text default null)
returns performance_reviews
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_row performance_reviews;
  v_status text;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  select * into v_row from performance_reviews
   where id = p_review_id and tenant_id = current_tenant_id();
  if v_row.id is null then
    raise exception 'review not found';
  end if;
  if v_row.employee_id <> v_actor then
    raise exception 'not authorized to fill this self-assessment';
  end if;
  select status into v_status from review_cycles where id = v_row.cycle_id;
  if v_status <> 'OPEN' then
    raise exception 'review cycle is closed';
  end if;
  if v_row.mgr_rating is not null then
    raise exception 'manager review already submitted';
  end if;
  if p_rating is null or p_rating not between 0 and 3 then
    raise exception 'invalid rating';
  end if;
  if v_note is not null and char_length(v_note) > 1000 then
    raise exception 'note is too long';
  end if;
  update performance_reviews
     set self_rating = p_rating, self_note = v_note, self_at = now()
   where id = p_review_id
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function submit_manager_review(p_review_id uuid, p_rating integer, p_note text default null)
returns performance_reviews
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_row performance_reviews;
  v_status text;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  select * into v_row from performance_reviews
   where id = p_review_id and tenant_id = current_tenant_id();
  if v_row.id is null then
    raise exception 'review not found';
  end if;
  if v_row.employee_id = v_actor then
    raise exception 'not authorized to review yourself';
  end if;
  if not can_review_worker(v_row.employee_id) then
    raise exception 'not authorized to review this employee';
  end if;
  select status into v_status from review_cycles where id = v_row.cycle_id;
  if v_status <> 'OPEN' then
    raise exception 'review cycle is closed';
  end if;
  if v_row.self_rating is null then
    raise exception 'self-assessment comes first';
  end if;
  if v_row.calib_rating is not null then
    raise exception 'review already calibrated';
  end if;
  if p_rating is null or p_rating not between 0 and 3 then
    raise exception 'invalid rating';
  end if;
  if v_note is not null and char_length(v_note) > 1000 then
    raise exception 'note is too long';
  end if;
  update performance_reviews
     set mgr_rating = p_rating, mgr_note = v_note, mgr_at = now(), mgr_by = v_actor
   where id = p_review_id
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function calibrate_review(p_review_id uuid, p_rating integer default null, p_note text default null)
returns performance_reviews
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_row performance_reviews;
  v_status text;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  select * into v_row from performance_reviews
   where id = p_review_id and tenant_id = current_tenant_id();
  if v_row.id is null then
    raise exception 'review not found';
  end if;
  if v_row.employee_id = v_actor then
    raise exception 'not authorized to review yourself';
  end if;
  if not can_review_worker(v_row.employee_id) then
    raise exception 'not authorized to review this employee';
  end if;
  select status into v_status from review_cycles where id = v_row.cycle_id;
  if v_status <> 'OPEN' then
    raise exception 'review cycle is closed';
  end if;
  if v_row.mgr_rating is null then
    raise exception 'manager review comes first';
  end if;
  if p_rating is not null and p_rating not between 0 and 3 then
    raise exception 'invalid rating';
  end if;
  if v_note is not null and char_length(v_note) > 1000 then
    raise exception 'note is too long';
  end if;
  update performance_reviews
     set calib_rating = coalesce(p_rating, mgr_rating),
         calib_note = coalesce(v_note, mgr_note),
         calib_at = now(), calib_by = v_actor
   where id = p_review_id
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function add_worker_to_open_cycles()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.role = 'employee' then
    insert into performance_reviews (tenant_id, cycle_id, employee_id)
    select new.tenant_id, c.id, new.id
      from review_cycles c
     where c.tenant_id = new.tenant_id and c.status = 'OPEN'
    on conflict (cycle_id, employee_id) do nothing;
  end if;
  return new;
end;
$$;

create trigger trg_add_worker_to_open_cycles
  after insert on workers
  for each row execute function add_worker_to_open_cycles();

-- Seed: siklus Semester 2 2026 untuk PT ABC F&B Company. Deadline dihitung dari
-- hari migration diterapkan (seperti migration 012), supaya demo tetap aktif.
insert into review_cycles (id, tenant_id, name, starts_on, ends_on, due_self, due_mgr, due_calib)
values ('d2000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001',
        '{"id":"Semester 2 2026","en":"H2 2026"}', '2026-07-01', '2026-12-31',
        (now() at time zone 'Asia/Jakarta')::date + 3,
        (now() at time zone 'Asia/Jakarta')::date + 10,
        (now() at time zone 'Asia/Jakarta')::date + 17);

insert into performance_reviews (id, tenant_id, cycle_id, employee_id, potential,
                                 self_rating, self_note, self_at, mgr_rating, mgr_note, mgr_at, mgr_by)
values
  ('d3000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-000000000001',
   '60000000-0000-0000-0000-000000000001', 2, null, null, null, null, null, null, null),
  ('d3000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-000000000001',
   '60000000-0000-0000-0000-000000000002', 1, 1,
   'Skrip upsell 3 kalimat sudah dilatihkan ke kasir baru, masih perlu latihan lanjutan.', now() - interval '2 days',
   null, null, null, null),
  ('d3000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-000000000001',
   '60000000-0000-0000-0000-000000000003', 2, 1,
   'Checklist penutupan dan inspeksi silang selesai tepat waktu.', now() - interval '3 days',
   2, 'Konsisten. Inisiatif inspeksi silang ke Setiabudi bagus.', now() - interval '1 day',
   '60000000-0000-0000-0000-000000000004');

insert into performance_reviews (tenant_id, cycle_id, employee_id)
select w.tenant_id, 'd2000000-0000-0000-0000-000000000001', w.id
  from workers w
 where w.tenant_id = '00000000-0000-0000-0000-000000000001' and w.role = 'employee'
on conflict (cycle_id, employee_id) do nothing;

revoke execute on function submit_self_assessment(uuid, integer, text) from public, anon;
revoke execute on function submit_manager_review(uuid, integer, text) from public, anon;
revoke execute on function calibrate_review(uuid, integer, text) from public, anon;
revoke execute on function can_review_worker(uuid) from public, anon;
grant execute on function submit_self_assessment(uuid, integer, text) to authenticated;
grant execute on function submit_manager_review(uuid, integer, text) to authenticated;
grant execute on function calibrate_review(uuid, integer, text) to authenticated;
grant execute on function can_review_worker(uuid) to authenticated;
