-- 043: inisiatif lintas outlet beserta milestone-nya.
--
-- Tabel initiatives dan initiative_milestones sudah ada sejak 002 tapi kosong dan tanpa jalur tulis. Inisiatif adalah
-- program perusahaan yang melintasi outlet (misalnya "Seragam SOP dapur di 4 outlet"), terpisah dari Prioritas Utama
-- per tim. Migration ini memberinya bentuk lengkap dan jalur tulis yang dijaga server:
-- 1. initiatives: keterangan, cakupan outlet (team_ids, kosong = seluruh perusahaan), pencatat dan waktu dibuat dan
--    diubah, dan arsip. Status dibatasi ON_TRACK, WATCH, OFF_TRACK, DONE.
-- 2. initiative_milestones: urutan, kapan dan oleh siapa ditandai selesai, dan arsip.
-- 3. progress_pct dihitung server dari milestone aktif yang selesai dibagi semua milestone aktif (0 kalau belum ada;
--    layar menulis "Belum ada milestone", bukan 0%). Tidak pernah diketik manual.
-- 4. RPC save_initiative(): hanya eksekutif dan HC. Nama wajib (120), keterangan 1.000, PIC wajib dan satu tenant,
--    sponsor opsional, tanggal selesai wajib dan tidak sebelum tanggal mulai, outlet harus tim di tenant yang sama,
--    paling banyak 12 milestone (judul wajib 120, tanggal opsional). Milestone yang tidak dikirim lagi diarsipkan,
--    jadi status selesainya tidak hilang saat judul milestone lain diubah.
-- 5. RPC set_initiative_milestone(): tandai selesai atau belum; boleh PIC inisiatif, sponsornya, eksekutif, atau HC.
-- 6. RPC archive_initiative(): hanya eksekutif dan HC, arsip (tanpa DELETE).
-- 7. Semua perubahan tercatat di audit_log lewat log_audit_event(). Tabel tetap hanya punya policy SELECT seluas
--    tenant; semua tulisan lewat fungsi.
-- 8. Tidak ada DROP, REVOKE ALL, atau DELETE.

alter table initiatives
  add column if not exists description text,
  add column if not exists team_ids uuid[] not null default '{}',
  add column if not exists created_by uuid references workers(id),
  add column if not exists updated_by uuid references workers(id),
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists archived_at timestamptz;

alter table initiatives
  add constraint initiatives_status_check check (status in ('ON_TRACK', 'WATCH', 'OFF_TRACK', 'DONE'));

alter table initiative_milestones
  add column if not exists position integer not null default 0,
  add column if not exists done_at timestamptz,
  add column if not exists done_by uuid references workers(id),
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists archived_at timestamptz;

create index if not exists idx_initiative_milestones_initiative on initiative_milestones(initiative_id);

create trigger trg_audit_initiatives
  after insert or update or delete on initiatives
  for each row execute function log_audit_event();

create trigger trg_audit_initiative_milestones
  after insert or update or delete on initiative_milestones
  for each row execute function log_audit_event();

create or replace function initiative_recount(p_id uuid)
returns numeric
language sql
security definer
set search_path = public
as $$
  update initiatives i
     set progress_pct = coalesce((
       select round(100.0 * count(*) filter (where m.done) / nullif(count(*), 0))
         from initiative_milestones m
        where m.initiative_id = i.id and m.archived_at is null), 0)
   where i.id = p_id
  returning progress_pct;
$$;

create or replace function save_initiative(
  p_id uuid,
  p_name text,
  p_description text,
  p_owner_id uuid,
  p_sponsor_id uuid,
  p_team_ids uuid[],
  p_start_at date,
  p_end_at date,
  p_status text,
  p_milestones jsonb
)
returns initiatives
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_role text := current_worker_role();
  v_tenant uuid := current_tenant_id();
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_desc text := nullif(btrim(coalesce(p_description, '')), '');
  v_teams uuid[] := coalesce((select array_agg(distinct x) from unnest(coalesce(p_team_ids, '{}')) x), '{}');
  v_ini initiatives;
  v_e jsonb;
  v_pos integer := 0;
  v_title text;
  v_due date;
  v_mid uuid;
  v_keep uuid[] := '{}';
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  if v_role not in ('executive', 'hc_admin') then
    raise exception 'not authorized to edit initiatives';
  end if;
  if v_name is null then
    raise exception 'initiative name is required';
  end if;
  if char_length(v_name) > 120 or char_length(coalesce(v_desc, '')) > 1000 then
    raise exception 'text is too long';
  end if;
  if p_owner_id is null then
    raise exception 'owner is required';
  end if;
  if not exists (select 1 from workers where id = p_owner_id and tenant_id = v_tenant) then
    raise exception 'worker not found';
  end if;
  if p_sponsor_id is not null and not exists (select 1 from workers where id = p_sponsor_id and tenant_id = v_tenant) then
    raise exception 'worker not found';
  end if;
  if p_end_at is null then
    raise exception 'end date is required';
  end if;
  if p_start_at is not null and p_start_at > p_end_at then
    raise exception 'invalid period';
  end if;
  if p_status is null or p_status not in ('ON_TRACK', 'WATCH', 'OFF_TRACK', 'DONE') then
    raise exception 'invalid status';
  end if;
  if exists (select 1 from unnest(v_teams) x where not exists (select 1 from teams t where t.id = x and t.tenant_id = v_tenant)) then
    raise exception 'team not found';
  end if;
  if p_milestones is null or jsonb_typeof(p_milestones) <> 'array' then
    raise exception 'invalid milestones';
  end if;
  if jsonb_array_length(p_milestones) > 12 then
    raise exception 'too many milestones';
  end if;

  if p_id is null then
    insert into initiatives (tenant_id, owner_id, sponsor_id, name, description, team_ids, start_at, end_at, status,
                             created_by, updated_by)
    values (v_tenant, p_owner_id, p_sponsor_id, v_name, v_desc, v_teams, p_start_at, p_end_at, p_status, v_actor, v_actor)
    returning * into v_ini;
  else
    select * into v_ini from initiatives where id = p_id and tenant_id = v_tenant and archived_at is null for update;
    if not found then
      raise exception 'initiative not found';
    end if;
    update initiatives
       set owner_id = p_owner_id, sponsor_id = p_sponsor_id, name = v_name, description = v_desc, team_ids = v_teams,
           start_at = p_start_at, end_at = p_end_at, status = p_status, updated_by = v_actor, updated_at = now(),
           version = version + 1
     where id = p_id
    returning * into v_ini;
  end if;

  for v_e in select e from jsonb_array_elements(p_milestones) as x(e) loop
    if jsonb_typeof(v_e) <> 'object' then
      raise exception 'invalid milestones';
    end if;
    v_title := nullif(btrim(coalesce(v_e->>'title', '')), '');
    if v_title is null then
      raise exception 'milestone title is required';
    end if;
    if char_length(v_title) > 120 then
      raise exception 'text is too long';
    end if;
    v_due := null;
    if nullif(btrim(coalesce(v_e->>'due_at', '')), '') is not null then
      begin
        v_due := (v_e->>'due_at')::date;
      exception when others then
        raise exception 'invalid milestone date';
      end;
    end if;
    v_pos := v_pos + 1;
    v_mid := null;
    if nullif(v_e->>'id', '') is not null then
      begin
        v_mid := (v_e->>'id')::uuid;
      exception when others then
        raise exception 'milestone not found';
      end;
      update initiative_milestones
         set title = v_title, due_at = v_due, position = v_pos
       where id = v_mid and initiative_id = v_ini.id and archived_at is null;
      if not found then
        raise exception 'milestone not found';
      end if;
    else
      insert into initiative_milestones (tenant_id, initiative_id, title, due_at, position)
      values (v_tenant, v_ini.id, v_title, v_due, v_pos)
      returning id into v_mid;
    end if;
    v_keep := v_keep || v_mid;
  end loop;

  update initiative_milestones set archived_at = now()
   where initiative_id = v_ini.id and archived_at is null and not (id = any(v_keep));

  perform initiative_recount(v_ini.id);
  select * into v_ini from initiatives where id = v_ini.id;
  return v_ini;
end;
$$;

create or replace function set_initiative_milestone(p_id uuid, p_done boolean)
returns initiative_milestones
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_role text := current_worker_role();
  v_tenant uuid := current_tenant_id();
  v_ms initiative_milestones;
  v_ini initiatives;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  select * into v_ms from initiative_milestones where id = p_id and tenant_id = v_tenant and archived_at is null for update;
  if not found then
    raise exception 'milestone not found';
  end if;
  select * into v_ini from initiatives where id = v_ms.initiative_id and archived_at is null;
  if not found then
    raise exception 'initiative not found';
  end if;
  if not (v_role in ('executive', 'hc_admin') or v_ini.owner_id = v_actor or v_ini.sponsor_id = v_actor) then
    raise exception 'not authorized to edit initiatives';
  end if;
  update initiative_milestones
     set done = coalesce(p_done, false),
         done_at = case when coalesce(p_done, false) then now() else null end,
         done_by = case when coalesce(p_done, false) then v_actor else null end
   where id = p_id
  returning * into v_ms;
  perform initiative_recount(v_ini.id);
  update initiatives set updated_by = v_actor, updated_at = now(), version = version + 1 where id = v_ini.id;
  return v_ms;
end;
$$;

create or replace function archive_initiative(p_id uuid)
returns initiatives
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_ini initiatives;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  if current_worker_role() not in ('executive', 'hc_admin') then
    raise exception 'not authorized to edit initiatives';
  end if;
  update initiatives set archived_at = now(), updated_by = v_actor, updated_at = now()
   where id = p_id and tenant_id = current_tenant_id() and archived_at is null
  returning * into v_ini;
  if not found then
    raise exception 'initiative not found';
  end if;
  return v_ini;
end;
$$;

revoke execute on function initiative_recount(uuid) from public;
revoke execute on function initiative_recount(uuid) from anon;
revoke execute on function initiative_recount(uuid) from authenticated;
revoke execute on function save_initiative(uuid, text, text, uuid, uuid, uuid[], date, date, text, jsonb) from public;
revoke execute on function save_initiative(uuid, text, text, uuid, uuid, uuid[], date, date, text, jsonb) from anon;
grant execute on function save_initiative(uuid, text, text, uuid, uuid, uuid[], date, date, text, jsonb) to authenticated;
revoke execute on function set_initiative_milestone(uuid, boolean) from public;
revoke execute on function set_initiative_milestone(uuid, boolean) from anon;
grant execute on function set_initiative_milestone(uuid, boolean) to authenticated;
revoke execute on function archive_initiative(uuid) from public;
revoke execute on function archive_initiative(uuid) from anon;
grant execute on function archive_initiative(uuid) to authenticated;
