-- Tugas rutin per shift dan serah terima antar shift.
--
-- Kebutuhan dasar outlet F&B: pekerjaan yang berulang tiap hari atau tiap
-- shift (cek suhu chiller, checklist buka dan tutup outlet, rekap kas) dan
-- catatan serah terima dari shift yang selesai ke shift berikutnya. Sampai
-- migration 015 setiap work item dibuat sekali pakai; recurring_templates
-- sudah ada sejak 002 tapi belum pernah dipakai dan kolom rrule-nya tidak
-- punya pembaca. Migration ini menghidupkannya.
--
-- Keputusan desain:
-- 1. Shift adalah data per tim (tabel shifts), bukan aturan di kode. Jam
--    shift berbeda antar outlet; seed hanya mengisi Outlet Dago (017).
-- 2. recurring_templates memakai days_of_week (ISO 1=Senin .. 7=Minggu)
--    sebagai pengganti rrule. Pola rutin outlet cukup "setiap hari" atau
--    "hari tertentu", dan days_of_week bisa divalidasi serta dibaca langsung
--    di SQL tanpa parser RFC 5545. Tabel ini masih kosong, jadi aman diubah.
--    Kolom rrule dibiarkan (nullable, tidak dipakai).
--    title ikut jadi jsonb dwibahasa seperti work_items sejak 008.
-- 3. Instance harian dibuat malas (lazy) oleh RPC generate_routine_work(),
--    yang dipanggil frontend setiap memuat daftar tugas. Idempoten lewat
--    unique index (template_id, occurrence_date), jadi aman dipanggil
--    berkali-kali dan dari banyak perangkat sekaligus. Tidak butuh pg_cron.
-- 4. Tanggal dan jam dihitung di zona Asia/Jakarta (lokasi tenant seed).
--    Kalau nanti ada tenant di zona lain, zona ini perlu pindah ke kolom
--    tenant; dicatat di README.
-- 5. Semua tulisan ke tiga objek baru lewat RPC security definer dengan
--    identitas pemanggil (pola yang sama dengan 010 dan 014). Tidak ada
--    policy INSERT/UPDATE langsung untuk client.

-- 1. Shift per tim
create table shifts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  team_id uuid not null references teams(id),
  code text not null,
  name jsonb not null,
  starts_at time not null,
  ends_at time not null,
  position integer not null default 0,
  active boolean not null default true,
  unique (team_id, code)
);
alter table shifts enable row level security;
create policy tenant_isolation_select on shifts for select using (tenant_id = current_tenant_id());

-- 2. Template tugas rutin (tabel dari 002, masih kosong). title jadi jsonb dwibahasa;
--    rrule tidak dipakai lagi (diganti days_of_week), dibiarkan tapi boleh kosong.
--    Sengaja tanpa DROP COLUMN supaya migration tidak tertahan konfirmasi
--    statement destruktif saat diterapkan lewat apply_migration.
alter table recurring_templates alter column title type jsonb using jsonb_build_object('id', title, 'en', title);
alter table recurring_templates alter column rrule drop not null;
comment on column recurring_templates.rrule is 'Tidak dipakai sejak migration 016; jadwal memakai days_of_week.';
alter table recurring_templates
  add column shift_id uuid references shifts(id),
  add column days_of_week smallint[] not null default '{1,2,3,4,5,6,7}',
  add column owner_id uuid not null references workers(id),
  add column checklist jsonb not null default '[]'::jsonb,
  add column priority_level text not null default 'NORMAL' check (priority_level in ('LOW','NORMAL','HIGH','URGENT')),
  add column active boolean not null default true,
  add column created_by uuid not null references workers(id),
  add column created_at timestamptz not null default now(),
  add constraint recurring_templates_days_valid check (
    cardinality(days_of_week) between 1 and 7 and days_of_week <@ '{1,2,3,4,5,6,7}'::smallint[]
  ),
  add constraint recurring_templates_checklist_array check (jsonb_typeof(checklist) = 'array');

-- 3. Instance rutin di work_items
alter table work_items
  add column shift_id uuid references shifts(id),
  add column occurrence_date date;
create unique index work_items_template_occurrence_uniq
  on work_items (template_id, occurrence_date) where template_id is not null;
create index work_items_occurrence_date_idx on work_items (occurrence_date) where occurrence_date is not null;

-- 4. Serah terima antar shift
create table shift_handovers (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  team_id uuid not null references teams(id),
  shift_id uuid not null references shifts(id),
  handover_date date not null,
  author_id uuid not null references workers(id),
  note text not null check (char_length(btrim(note)) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index shift_handovers_team_recent_idx on shift_handovers (team_id, created_at desc);
alter table shift_handovers enable row level security;
create policy tenant_isolation_select on shift_handovers for select using (tenant_id = current_tenant_id());

create trigger trg_audit_recurring_templates after insert or update or delete on recurring_templates
  for each row execute function log_audit_event();
create trigger trg_audit_shift_handovers after insert or update or delete on shift_handovers
  for each row execute function log_audit_event();

-- 5. Buat instance tugas rutin untuk satu tanggal (default hari ini WIB).
--    Rentang dibatasi kemarin sampai besok supaya tidak bisa dipakai untuk
--    membanjiri tabel. Mengembalikan jumlah instance baru.
create or replace function generate_routine_work(p_date date default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant uuid := current_tenant_id();
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_date date := coalesce(p_date, (now() at time zone 'Asia/Jakarta')::date);
  v_dow smallint := extract(isodow from coalesce(p_date, (now() at time zone 'Asia/Jakarta')::date))::smallint;
  v_count integer := 0;
  v_item_id uuid;
  v_due timestamptz;
  r record;
begin
  if v_tenant is null then
    raise exception 'not authenticated';
  end if;
  if v_date < v_today - 1 or v_date > v_today + 1 then
    raise exception 'date out of range';
  end if;

  for r in
    select t.*, s.starts_at as shift_start, s.ends_at as shift_end
    from recurring_templates t
    left join shifts s on s.id = t.shift_id
    where t.tenant_id = v_tenant and t.active and v_dow = any(t.days_of_week)
  loop
    v_due := (
      (v_date + case when r.shift_end is not null and r.shift_end <= r.shift_start then 1 else 0 end)
      + coalesce(r.shift_end, time '17:00')
    ) at time zone 'Asia/Jakarta';

    v_item_id := null;
    insert into work_items (tenant_id, team_id, type, title, creator_id, owner_id, status,
                            priority_level, due_at, template_id, shift_id, occurrence_date, qty)
    values (v_tenant, r.team_id, 'RECURRING_WORK', r.title, r.created_by, r.owner_id, 'READY',
            r.priority_level, v_due, r.id, r.shift_id, v_date, 1)
    on conflict (template_id, occurrence_date) where template_id is not null do nothing
    returning id into v_item_id;

    if v_item_id is not null then
      insert into checklist_items (tenant_id, work_item_id, title, position)
      select v_tenant, v_item_id, c.value, c.ord::integer
      from jsonb_array_elements(r.checklist) with ordinality as c(value, ord);
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$$;

-- 6. Template baru (manajer untuk timnya sendiri, eksekutif/HC tenant-wide).
--    Tim diturunkan dari penanggung jawab, bukan dari input client.
create or replace function create_routine_template(
  p_title_id text,
  p_title_en text,
  p_shift_id uuid,
  p_days smallint[],
  p_owner_id uuid,
  p_checklist jsonb default '[]'::jsonb,
  p_priority_level text default 'NORMAL'
)
returns recurring_templates
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_role text := current_worker_role();
  v_tenant uuid := current_tenant_id();
  v_team uuid;
  v_actor_team uuid;
  v_tpl recurring_templates;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  if v_role not in ('manager','executive','hc_admin') then
    raise exception 'not authorized to manage routine tasks';
  end if;
  if p_title_id is null or btrim(p_title_id) = '' then
    raise exception 'title is required';
  end if;
  if p_days is null or cardinality(p_days) = 0 then
    raise exception 'at least one day is required';
  end if;

  select team_id into v_team from workers where id = p_owner_id and tenant_id = v_tenant;
  if v_team is null then
    raise exception 'owner has no team';
  end if;
  if v_role = 'manager' then
    select team_id into v_actor_team from workers where id = v_actor;
    if v_actor_team is distinct from v_team then
      raise exception 'not authorized to manage routine tasks for another team';
    end if;
  end if;
  if p_shift_id is not null and not exists (select 1 from shifts where id = p_shift_id and team_id = v_team) then
    raise exception 'shift does not belong to this team';
  end if;

  insert into recurring_templates (tenant_id, team_id, title, shift_id, days_of_week, owner_id,
                                   checklist, priority_level, created_by)
  values (
    v_tenant, v_team,
    jsonb_build_object('id', btrim(p_title_id), 'en', coalesce(nullif(btrim(p_title_en), ''), btrim(p_title_id))),
    p_shift_id, (select array_agg(distinct d order by d) from unnest(p_days) d),
    p_owner_id, coalesce(p_checklist, '[]'::jsonb), coalesce(p_priority_level, 'NORMAL'), v_actor
  )
  returning * into v_tpl;

  perform generate_routine_work();
  return v_tpl;
end;
$$;

-- 7. Jeda atau aktifkan lagi template (instance yang sudah dibuat tetap ada).
create or replace function set_routine_template_active(p_template_id uuid, p_active boolean)
returns recurring_templates
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_role text := current_worker_role();
  v_tpl recurring_templates;
begin
  select * into v_tpl from recurring_templates where id = p_template_id and tenant_id = current_tenant_id();
  if v_tpl.id is null then
    raise exception 'routine template not found';
  end if;
  if not (
    v_role in ('executive','hc_admin')
    or (v_role = 'manager' and v_tpl.team_id = (select team_id from workers where id = v_actor))
  ) then
    raise exception 'not authorized to manage routine tasks';
  end if;

  update recurring_templates set active = p_active where id = p_template_id returning * into v_tpl;
  if p_active then
    perform generate_routine_work();
  end if;
  return v_tpl;
end;
$$;

-- 8. Catatan serah terima shift. Penulis dan tim selalu dari pemanggil.
create or replace function submit_shift_handover(p_shift_id uuid, p_note text)
returns shift_handovers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_tenant uuid := current_tenant_id();
  v_team uuid;
  v_row shift_handovers;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  select team_id into v_team from workers where id = v_actor;
  if v_team is null then
    raise exception 'only team members can write a shift handover';
  end if;
  if not exists (select 1 from shifts where id = p_shift_id and team_id = v_team) then
    raise exception 'shift does not belong to your team';
  end if;
  if p_note is null or btrim(p_note) = '' then
    raise exception 'note is required';
  end if;

  insert into shift_handovers (tenant_id, team_id, shift_id, handover_date, author_id, note)
  values (v_tenant, v_team, p_shift_id, (now() at time zone 'Asia/Jakarta')::date, v_actor, btrim(p_note))
  returning * into v_row;
  return v_row;
end;
$$;

revoke execute on function generate_routine_work(date) from public, anon;
revoke execute on function create_routine_template(text, text, uuid, smallint[], uuid, jsonb, text) from public, anon;
revoke execute on function set_routine_template_active(uuid, boolean) from public, anon;
revoke execute on function submit_shift_handover(uuid, text) from public, anon;
grant execute on function generate_routine_work(date) to authenticated;
grant execute on function create_routine_template(text, text, uuid, smallint[], uuid, jsonb, text) to authenticated;
grant execute on function set_routine_template_active(uuid, boolean) to authenticated;
grant execute on function submit_shift_handover(uuid, text) to authenticated;
