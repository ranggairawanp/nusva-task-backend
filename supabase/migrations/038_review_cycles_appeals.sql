-- Siklus penilaian multi-periode dan banding.
--
-- Keputusan desain:
-- 1. Siklus dibuka dan ditutup dari aplikasi (HC atau eksekutif). Satu siklus terbuka pada satu waktu,
--    jadi RPC lama yang membaca "siklus OPEN terbaru" tetap benar. Siklus yang ditutup tetap terbaca
--    sebagai riwayat lewat policy SELECT yang sudah ada (karyawan barisnya sendiri, manajer timnya).
-- 2. Banding (right of reply). Karyawan boleh mengajukan banding atas rating akhir (setelah kalibrasi)
--    sampai review_cycles.appeal_until, satu kali per penilaian, dengan alasan tertulis. Atasan boleh
--    menanggapi. HC atau eksekutif memutuskan, bukan atasan yang menilai, dan wajib menulis alasan.
--    HC tidak bisa memutuskan sebelum atasan menanggapi atau 3 hari lewat sejak banding diajukan
--    (kalau tim punya manajer), supaya atasan tidak terkejut oleh keputusan tentang penilaiannya.
-- 3. Keputusan diterima mengubah rating akhir (calib_rating) dan menyimpan rating sebelum dan sesudahnya
--    di baris banding. Banding ditolak tidak mengubah apa pun. Kedua keputusan tercatat di audit_log.
-- 4. Siklus tidak bisa ditutup selama ada banding menunggu atau masa banding belum lewat, supaya hak
--    banding tidak hilang karena siklus ditutup lebih awal.
-- 5. Baca per peran dipaksa policy: karyawan bandingnya sendiri, manajer banding timnya, eksekutif dan HC
--    seluruh tenant. Tulis hanya lewat RPC. Tidak ada DROP, REVOKE ALL, atau DELETE.

alter table review_cycles add column appeal_until date;
update review_cycles set appeal_until = due_calib + 7 where appeal_until is null;
alter table review_cycles add constraint review_cycles_appeal_check
  check (appeal_until is null or appeal_until >= due_calib);

create table review_appeals (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  review_id uuid not null unique references performance_reviews(id),
  cycle_id uuid not null references review_cycles(id),
  employee_id uuid not null references workers(id),
  reason text not null check (char_length(reason) between 10 and 1000),
  from_rating smallint not null check (from_rating between 0 and 3),
  filed_at timestamptz not null default now(),
  mgr_response text check (mgr_response is null or char_length(mgr_response) between 1 and 1000),
  mgr_response_at timestamptz,
  mgr_response_by uuid references workers(id),
  status text not null default 'PENDING' check (status in ('PENDING','ACCEPTED','REJECTED')),
  decision_note text check (decision_note is null or char_length(decision_note) between 1 and 1000),
  to_rating smallint check (to_rating between 0 and 3),
  decided_at timestamptz,
  decided_by uuid references workers(id),
  check (status = 'PENDING' or (decision_note is not null and decided_at is not null and decided_by is not null)),
  check (status <> 'ACCEPTED' or (to_rating is not null and to_rating <> from_rating))
);
create index review_appeals_cycle_idx on review_appeals (cycle_id, status);
create index review_appeals_employee_idx on review_appeals (employee_id);
alter table review_appeals enable row level security;
grant select on review_appeals to authenticated;
create policy review_appeals_select on review_appeals for select
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
create trigger trg_audit_review_appeals after insert or update or delete on review_appeals
  for each row execute function log_audit_event();

create or replace function create_review_cycle(
  p_name_id text, p_name_en text, p_starts_on date, p_ends_on date,
  p_due_self date, p_due_mgr date, p_due_calib date, p_appeal_until date default null)
returns review_cycles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant uuid := current_tenant_id();
  v_name_id text := nullif(btrim(coalesce(p_name_id, '')), '');
  v_name_en text := nullif(btrim(coalesce(p_name_en, '')), '');
  v_appeal date := coalesce(p_appeal_until, p_due_calib + 7);
  v_row review_cycles;
begin
  if current_worker_id() is null then
    raise exception 'not authenticated';
  end if;
  if current_worker_role() not in ('executive','hc_admin') then
    raise exception 'not authorized to manage review cycles';
  end if;
  if v_name_id is null or char_length(v_name_id) > 80 or char_length(coalesce(v_name_en, '')) > 80 then
    raise exception 'invalid cycle name';
  end if;
  if p_starts_on is null or p_ends_on is null or p_ends_on < p_starts_on then
    raise exception 'invalid cycle dates';
  end if;
  if p_due_self is null or p_due_mgr is null or p_due_calib is null
     or p_due_self > p_due_mgr or p_due_mgr > p_due_calib or p_due_self < p_starts_on then
    raise exception 'invalid cycle deadlines';
  end if;
  if v_appeal < p_due_calib then
    raise exception 'invalid appeal deadline';
  end if;
  if exists (select 1 from review_cycles where tenant_id = v_tenant and status = 'OPEN') then
    raise exception 'a review cycle is still open';
  end if;
  insert into review_cycles (tenant_id, name, starts_on, ends_on, due_self, due_mgr, due_calib, appeal_until)
  values (v_tenant, jsonb_build_object('id', v_name_id, 'en', coalesce(v_name_en, v_name_id)),
          p_starts_on, p_ends_on, p_due_self, p_due_mgr, p_due_calib, v_appeal)
  returning * into v_row;
  insert into performance_reviews (tenant_id, cycle_id, employee_id)
  select v_tenant, v_row.id, w.id from workers w
   where w.tenant_id = v_tenant and w.role = 'employee'
  on conflict (cycle_id, employee_id) do nothing;
  return v_row;
end;
$$;

create or replace function close_review_cycle(p_cycle_id uuid)
returns review_cycles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row review_cycles;
begin
  if current_worker_id() is null then
    raise exception 'not authenticated';
  end if;
  if current_worker_role() not in ('executive','hc_admin') then
    raise exception 'not authorized to manage review cycles';
  end if;
  select * into v_row from review_cycles where id = p_cycle_id and tenant_id = current_tenant_id();
  if v_row.id is null then
    raise exception 'review cycle not found';
  end if;
  if v_row.status <> 'OPEN' then
    raise exception 'review cycle is closed';
  end if;
  if exists (select 1 from review_appeals where cycle_id = v_row.id and status = 'PENDING') then
    raise exception 'appeals are still pending';
  end if;
  if (now() at time zone 'Asia/Jakarta')::date <= coalesce(v_row.appeal_until, v_row.due_calib) then
    raise exception 'appeal window is still open';
  end if;
  update review_cycles set status = 'CLOSED' where id = v_row.id returning * into v_row;
  return v_row;
end;
$$;

create or replace function file_review_appeal(p_review_id uuid, p_reason text)
returns review_appeals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_rev performance_reviews;
  v_cycle review_cycles;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_row review_appeals;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  select * into v_rev from performance_reviews where id = p_review_id and tenant_id = current_tenant_id();
  if v_rev.id is null then
    raise exception 'review not found';
  end if;
  if v_rev.employee_id <> v_actor then
    raise exception 'not authorized to appeal this review';
  end if;
  select * into v_cycle from review_cycles where id = v_rev.cycle_id;
  if v_cycle.status <> 'OPEN' then
    raise exception 'review cycle is closed';
  end if;
  if v_rev.calib_rating is null then
    raise exception 'rating is not final yet';
  end if;
  if (now() at time zone 'Asia/Jakarta')::date > coalesce(v_cycle.appeal_until, v_cycle.due_calib) then
    raise exception 'appeal window has ended';
  end if;
  if exists (select 1 from review_appeals where review_id = v_rev.id) then
    raise exception 'appeal already filed';
  end if;
  if char_length(v_reason) < 10 then
    raise exception 'reason is too short';
  end if;
  if char_length(v_reason) > 1000 then
    raise exception 'reason is too long';
  end if;
  insert into review_appeals (tenant_id, review_id, cycle_id, employee_id, reason, from_rating)
  values (v_rev.tenant_id, v_rev.id, v_rev.cycle_id, v_actor, v_reason, v_rev.calib_rating)
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function respond_review_appeal(p_appeal_id uuid, p_response text)
returns review_appeals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_row review_appeals;
  v_text text := btrim(coalesce(p_response, ''));
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  select * into v_row from review_appeals where id = p_appeal_id and tenant_id = current_tenant_id();
  if v_row.id is null then
    raise exception 'appeal not found';
  end if;
  if current_worker_role() <> 'manager' or v_row.employee_id = v_actor
     or not can_review_worker(v_row.employee_id) then
    raise exception 'not authorized to respond to this appeal';
  end if;
  if v_row.status <> 'PENDING' then
    raise exception 'appeal already decided';
  end if;
  if char_length(v_text) = 0 then
    raise exception 'response is required';
  end if;
  if char_length(v_text) > 1000 then
    raise exception 'response is too long';
  end if;
  update review_appeals
     set mgr_response = v_text, mgr_response_at = now(), mgr_response_by = v_actor
   where id = p_appeal_id
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function decide_review_appeal(
  p_appeal_id uuid, p_accept boolean, p_new_rating integer default null, p_note text default null)
returns review_appeals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_row review_appeals;
  v_status text;
  v_team uuid;
  v_note text := btrim(coalesce(p_note, ''));
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  if current_worker_role() not in ('executive','hc_admin') then
    raise exception 'not authorized to decide appeals';
  end if;
  select * into v_row from review_appeals where id = p_appeal_id and tenant_id = current_tenant_id();
  if v_row.id is null then
    raise exception 'appeal not found';
  end if;
  if v_row.status <> 'PENDING' then
    raise exception 'appeal already decided';
  end if;
  select status into v_status from review_cycles where id = v_row.cycle_id;
  if v_status <> 'OPEN' then
    raise exception 'review cycle is closed';
  end if;
  select team_id into v_team from workers where id = v_row.employee_id;
  if v_row.mgr_response is null
     and v_row.filed_at + interval '3 days' > now()
     and exists (select 1 from workers m where m.tenant_id = v_row.tenant_id and m.team_id = v_team and m.role = 'manager') then
    raise exception 'manager response is pending';
  end if;
  if p_accept is null then
    raise exception 'decision is required';
  end if;
  if char_length(v_note) = 0 then
    raise exception 'decision note is required';
  end if;
  if char_length(v_note) > 1000 then
    raise exception 'note is too long';
  end if;
  if p_accept then
    if p_new_rating is null or p_new_rating not between 0 and 3 then
      raise exception 'invalid rating';
    end if;
    if p_new_rating = v_row.from_rating then
      raise exception 'rating is unchanged';
    end if;
    update performance_reviews set calib_rating = p_new_rating where id = v_row.review_id;
  end if;
  update review_appeals
     set status = case when p_accept then 'ACCEPTED' else 'REJECTED' end,
         to_rating = case when p_accept then p_new_rating else null end,
         decision_note = v_note, decided_at = now(), decided_by = v_actor
   where id = p_appeal_id
  returning * into v_row;
  return v_row;
end;
$$;

revoke execute on function create_review_cycle(text, text, date, date, date, date, date, date) from public, anon;
revoke execute on function close_review_cycle(uuid) from public, anon;
revoke execute on function file_review_appeal(uuid, text) from public, anon;
revoke execute on function respond_review_appeal(uuid, text) from public, anon;
revoke execute on function decide_review_appeal(uuid, boolean, integer, text) from public, anon;
grant execute on function create_review_cycle(text, text, date, date, date, date, date, date) to authenticated;
grant execute on function close_review_cycle(uuid) to authenticated;
grant execute on function file_review_appeal(uuid, text) to authenticated;
grant execute on function respond_review_appeal(uuid, text) to authenticated;
grant execute on function decide_review_appeal(uuid, boolean, integer, text) to authenticated;
