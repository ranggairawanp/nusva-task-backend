-- 044: komitmen mingguan per orang di Progres.
--
-- Tabel commitments dan commitment_checkins sudah ada sejak 002 tapi kosong dan tanpa jalur tulis. Komitmen adalah janji
-- kecil satu orang untuk satu minggu yang menggerakkan satu Prioritas Utama timnya (boleh menunjuk satu Action Plan),
-- misalnya "Tawarkan paket kopi susu ke 20 pelanggan pagi". Tempatnya di layar PERFORMANCE (Progres), bukan di daftar
-- tugas. Migration ini memberinya bentuk dan jalur tulis yang dijaga server:
-- 1. commitments: judul, Action Plan opsional, tim, minggu (Senin WIB), catatan hasil, pencatat dan waktu dibuat, diubah,
--    diputuskan, dan arsip. Status dibatasi OPEN, DONE, MISSED. Kolom lama target, current_value, dan confidence tidak dipakai;
--    period diisi tanggal Senin minggunya supaya tetap terisi.
-- 2. commitment_checkins: riwayat setiap perubahan hasil (status, catatan, siapa).
-- 3. RPC save_commitment(): hanya untuk diri sendiri, minggu berjalan, prioritas harus milik tim sendiri, Action Plan harus
--    bagian dari prioritas itu, judul wajib 200 karakter, paling banyak 3 komitmen aktif per orang per minggu. Mengubah hanya
--    selama masih OPEN dan masih di minggu yang sama.
-- 4. RPC set_commitment_result(): hanya pemiliknya, OPEN ke DONE atau MISSED (atau kembali ke OPEN), di minggu itu atau
--    minggu berikutnya (supaya komitmen minggu lalu bisa ditutup hari Senin). Catatan opsional 500 karakter.
-- 5. RPC archive_commitment(): hanya pemiliknya, hanya selama OPEN di minggu yang sama, arsip tanpa DELETE.
-- 6. Manajer, eksekutif, dan HC membaca (policy SELECT seluas tenant dari 005) tapi tidak menulis komitmen orang lain:
--    komitmen adalah janji pribadi, bukan target yang ditetapkan atasan. Tidak ada skor atau peringkat.
-- 7. Semua perubahan tercatat di audit_log lewat log_audit_event(). Tidak ada DROP, REVOKE ALL, atau DELETE.

alter table commitments
  add column if not exists title text,
  add column if not exists driver_id uuid references drivers(id),
  add column if not exists team_id uuid references teams(id),
  add column if not exists week_start date,
  add column if not exists note text,
  add column if not exists created_by uuid references workers(id),
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists decided_at timestamptz,
  add column if not exists archived_at timestamptz;

alter table commitments alter column status set default 'OPEN';

alter table commitments
  add constraint commitments_status_check check (status in ('OPEN', 'DONE', 'MISSED'));

create index if not exists idx_commitments_week on commitments(tenant_id, week_start);

alter table commitment_checkins
  add column if not exists status text,
  add column if not exists created_by uuid references workers(id);

create trigger trg_audit_commitments
  after insert or update or delete on commitments
  for each row execute function log_audit_event();

create trigger trg_audit_commitment_checkins
  after insert or update or delete on commitment_checkins
  for each row execute function log_audit_event();

create or replace function commitment_week() returns date
language sql
stable
set search_path = public
as $$
  select date_trunc('week', now() at time zone 'Asia/Jakarta')::date;
$$;

create or replace function save_commitment(p_id uuid, p_priority_id uuid, p_driver_id uuid, p_title text)
returns commitments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_tenant uuid := current_tenant_id();
  v_team uuid;
  v_week date := commitment_week();
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
  v_pri priorities;
  v_c commitments;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  select team_id into v_team from workers where id = v_actor;
  if v_title is null then
    raise exception 'commitment title is required';
  end if;
  if char_length(v_title) > 200 then
    raise exception 'text is too long';
  end if;
  select * into v_pri from priorities where id = p_priority_id and tenant_id = v_tenant;
  if not found then
    raise exception 'priority not found';
  end if;
  if v_team is null or v_pri.team_id <> v_team then
    raise exception 'priority is not in your team';
  end if;
  if p_driver_id is not null and not exists (select 1 from drivers where id = p_driver_id and priority_id = v_pri.id) then
    raise exception 'action plan is not part of this priority';
  end if;

  if p_id is not null then
    select * into v_c from commitments where id = p_id and tenant_id = v_tenant and archived_at is null for update;
    if not found then
      raise exception 'commitment not found';
    end if;
    if v_c.owner_id <> v_actor then
      raise exception 'not authorized to change this commitment';
    end if;
    if v_c.status <> 'OPEN' or v_c.week_start <> v_week then
      raise exception 'commitment is closed';
    end if;
    update commitments
       set title = v_title, priority_id = v_pri.id, driver_id = p_driver_id, updated_at = now(), version = version + 1
     where id = v_c.id
    returning * into v_c;
    return v_c;
  end if;

  if (select count(*) from commitments
       where owner_id = v_actor and week_start = v_week and archived_at is null) >= 3 then
    raise exception 'too many commitments';
  end if;
  insert into commitments (tenant_id, owner_id, priority_id, driver_id, team_id, period, week_start, title, status, created_by)
  values (v_tenant, v_actor, v_pri.id, p_driver_id, v_team, v_week::text, v_week, v_title, 'OPEN', v_actor)
  returning * into v_c;
  return v_c;
end;
$$;

create or replace function set_commitment_result(p_id uuid, p_status text, p_note text)
returns commitments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_tenant uuid := current_tenant_id();
  v_week date := commitment_week();
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_c commitments;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  if p_status is null or p_status not in ('OPEN', 'DONE', 'MISSED') then
    raise exception 'invalid status';
  end if;
  if char_length(coalesce(v_note, '')) > 500 then
    raise exception 'text is too long';
  end if;
  select * into v_c from commitments where id = p_id and tenant_id = v_tenant and archived_at is null for update;
  if not found then
    raise exception 'commitment not found';
  end if;
  if v_c.owner_id <> v_actor then
    raise exception 'not authorized to change this commitment';
  end if;
  if v_c.week_start < v_week - 7 then
    raise exception 'commitment is closed';
  end if;
  update commitments
     set status = p_status,
         note = case when p_status = 'OPEN' then null else v_note end,
         decided_at = case when p_status = 'OPEN' then null else now() end,
         updated_at = now(),
         version = version + 1
   where id = v_c.id
  returning * into v_c;
  insert into commitment_checkins (tenant_id, commitment_id, note, status, created_by)
  values (v_tenant, v_c.id, v_c.note, p_status, v_actor);
  return v_c;
end;
$$;

create or replace function archive_commitment(p_id uuid)
returns commitments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_c commitments;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  select * into v_c from commitments where id = p_id and tenant_id = current_tenant_id() and archived_at is null for update;
  if not found then
    raise exception 'commitment not found';
  end if;
  if v_c.owner_id <> v_actor then
    raise exception 'not authorized to change this commitment';
  end if;
  if v_c.status <> 'OPEN' or v_c.week_start <> commitment_week() then
    raise exception 'commitment is closed';
  end if;
  update commitments set archived_at = now(), updated_at = now() where id = v_c.id
  returning * into v_c;
  return v_c;
end;
$$;

revoke execute on function save_commitment(uuid, uuid, uuid, text) from public;
revoke execute on function save_commitment(uuid, uuid, uuid, text) from anon;
grant execute on function save_commitment(uuid, uuid, uuid, text) to authenticated;
revoke execute on function set_commitment_result(uuid, text, text) from public;
revoke execute on function set_commitment_result(uuid, text, text) from anon;
grant execute on function set_commitment_result(uuid, text, text) to authenticated;
revoke execute on function archive_commitment(uuid) from public;
revoke execute on function archive_commitment(uuid) from anon;
grant execute on function archive_commitment(uuid) to authenticated;
