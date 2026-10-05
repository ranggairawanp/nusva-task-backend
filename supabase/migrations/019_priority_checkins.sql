-- Weekly Check-in Prioritas Utama (layer PERFORMANCE).
--
-- Keputusan desain:
-- 1. Angka Action Plan (drivers.actual) sudah live: complete_work_item
--    menambahkannya otomatis dari tugas yang selesai (migration 010). Yang
--    belum punya jalur tulis adalah angka hasil bisnis (business_outcomes.
--    current_value). Angka itu diinput manusia, jadi tempatnya Weekly Check-in.
-- 2. Satu check-in per Prioritas Utama per minggu (week_start = Senin, zona
--    Asia/Jakarta). Mengisi ulang di minggu yang sama memperbarui baris itu,
--    bukan menambah baris baru, supaya riwayat tetap satu titik per minggu.
-- 3. Setiap check-in mencatat penginput dan waktunya, dan sekaligus mengisi
--    business_outcomes.reported_by/reported_at, sesuai aturan "setiap angka
--    menyebut asalnya".
-- 4. Status prioritas diturunkan dari check-in: ACHIEVED kalau angka sudah
--    melewati target (arah target dihitung dari baseline), selain itu
--    mengikuti keyakinan penginput (ON_TRACK, WATCH, OFF_TRACK -> AT_RISK).
-- 5. Baca seluas tenant (sama dengan priorities/drivers). Tulis hanya lewat
--    RPC submit_priority_checkin: manajer untuk prioritas timnya sendiri,
--    eksekutif/HC seluruh tenant. Tidak ada policy INSERT/UPDATE/DELETE.
-- 6. Tidak ada DROP, REVOKE ALL, atau perubahan kolom yang sudah ada.

create table priority_checkins (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  priority_id uuid not null references priorities(id) on delete cascade,
  week_start date not null,
  outcome_value numeric not null,
  confidence text not null check (confidence in ('ON_TRACK','WATCH','OFF_TRACK')),
  note text check (note is null or char_length(note) <= 500),
  created_by uuid not null references workers(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (priority_id, week_start)
);
create index priority_checkins_priority_recent_idx on priority_checkins (priority_id, week_start desc);
alter table priority_checkins enable row level security;
-- Hak SELECT ditulis eksplisit supaya tidak bergantung default privileges.
grant select on priority_checkins to authenticated;
create policy tenant_isolation_select on priority_checkins for select
  using (tenant_id = current_tenant_id());

create or replace function submit_priority_checkin(
  p_priority_id uuid,
  p_outcome_value numeric,
  p_confidence text,
  p_note text default null
)
returns priority_checkins
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_role text := current_worker_role();
  v_tenant uuid := current_tenant_id();
  v_week date := date_trunc('week', now() at time zone 'Asia/Jakarta')::date;
  v_pri priorities;
  v_bo business_outcomes;
  v_status text;
  v_row priority_checkins;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  select * into v_pri from priorities where id = p_priority_id and tenant_id = v_tenant;
  if v_pri.id is null then
    raise exception 'priority not found';
  end if;
  if not (
    v_role in ('executive','hc_admin')
    or (v_role = 'manager' and v_pri.team_id = (select team_id from workers where id = v_actor))
  ) then
    raise exception 'not authorized to check in on this priority';
  end if;
  if p_outcome_value is null then
    raise exception 'outcome value is required';
  end if;
  if p_confidence is null or p_confidence not in ('ON_TRACK','WATCH','OFF_TRACK') then
    raise exception 'invalid confidence';
  end if;
  if p_note is not null and char_length(p_note) > 500 then
    raise exception 'note is too long';
  end if;

  insert into priority_checkins (tenant_id, priority_id, week_start, outcome_value, confidence, note, created_by)
  values (v_tenant, v_pri.id, v_week, p_outcome_value, p_confidence, nullif(btrim(coalesce(p_note, '')), ''), v_actor)
  on conflict (priority_id, week_start) do update
    set outcome_value = excluded.outcome_value,
        confidence = excluded.confidence,
        note = excluded.note,
        created_by = excluded.created_by,
        updated_at = now()
  returning * into v_row;

  if v_pri.business_outcome_id is not null then
    update business_outcomes
       set current_value = p_outcome_value, reported_by = v_actor, reported_at = now()
     where id = v_pri.business_outcome_id
    returning * into v_bo;
  end if;

  v_status := case
    when v_bo.id is not null and v_bo.target is not null and v_bo.baseline is not null
         and ((v_bo.target >= v_bo.baseline and p_outcome_value >= v_bo.target)
           or (v_bo.target < v_bo.baseline and p_outcome_value <= v_bo.target)) then 'ACHIEVED'
    when p_confidence = 'ON_TRACK' then 'ON_TRACK'
    when p_confidence = 'WATCH' then 'WATCH'
    else 'AT_RISK'
  end;
  update priorities set status = v_status, updated_at = now()
   where id = v_pri.id and status is distinct from v_status;

  return v_row;
end;
$$;

revoke execute on function submit_priority_checkin(uuid, numeric, text, text) from public, anon;
grant execute on function submit_priority_checkin(uuid, numeric, text, text) to authenticated;
