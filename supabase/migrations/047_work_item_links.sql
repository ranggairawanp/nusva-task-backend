-- 047: menautkan tugas ke inisiatif dan ke komitmen mingguan.
--
-- Kolom work_items.initiative_id dan work_items.commitment_id sudah ada sejak 002 tapi tidak pernah diisi dan tidak punya
-- penjaga: policy work_items_write membolehkan pemilik tugas atau manajernya mengisi kolom apa pun, termasuk menunjuk
-- komitmen orang lain. Migration ini memberi keduanya jalur tulis yang dijaga server:
-- 1. Trigger guard_work_item_links(): kedua kolom hanya berubah lewat RPC di bawah (penanda sesi nusva.link_rpc), baik saat
--    INSERT maupun UPDATE. Tugas baru selalu lahir tanpa tautan.
-- 2. RPC set_work_item_commitment(p_work_item_id, p_commitment_id): tautkan (atau lepas dengan null) tugas ke komitmen.
--    Hanya pemilik komitmen, hanya untuk tugas miliknya sendiri, komitmen minggu ini atau minggu lalu (sama dengan jendela
--    menutup komitmen di 044), paling banyak 10 tugas per komitmen. Tugas yang sudah tertaut ke komitmen lain harus dilepas
--    dulu. Tugas selesai boleh ditautkan, karena justru itu yang menunjukkan komitmennya jalan.
-- 3. RPC set_work_item_initiative(p_work_item_id, p_initiative_id): tautkan (atau lepas) tugas ke inisiatif. Boleh eksekutif,
--    HC, PIC inisiatif, atau sponsornya. Kalau inisiatif berlingkup outlet, tim tugas harus salah satu outletnya. Paling banyak
--    50 tugas per inisiatif. Tugas yang sudah tertaut ke inisiatif lain harus dilepas dulu.
-- 4. Tautan hanya acuan: progres inisiatif tetap dari milestone (043) dan hasil komitmen tetap diputuskan pemiliknya (044).
--    Status tugas tidak berubah karena ditautkan.
-- 5. Komitmen atau inisiatif yang diarsipkan melepas tautannya otomatis, begitu juga outlet yang dikeluarkan dari cakupan
--    inisiatif.
-- 6. Perubahan tercatat di audit_log lewat trigger audit work_items yang sudah ada. Tidak ada DROP, REVOKE ALL, atau DELETE.

create index if not exists idx_work_items_initiative on work_items(initiative_id) where initiative_id is not null;
create index if not exists idx_work_items_commitment on work_items(commitment_id) where commitment_id is not null;

create or replace function guard_work_item_links()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_rpc boolean := coalesce(current_setting('nusva.link_rpc', true), '') = 'on';
begin
  if v_rpc then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.initiative_id is not null or new.commitment_id is not null then
      raise exception 'links can only change through the link flow';
    end if;
  elsif new.initiative_id is distinct from old.initiative_id
     or new.commitment_id is distinct from old.commitment_id then
    raise exception 'links can only change through the link flow';
  end if;
  return new;
end;
$$;

create trigger trg_guard_work_item_links
  before insert or update on work_items
  for each row execute function guard_work_item_links();

create or replace function set_work_item_commitment(p_work_item_id uuid, p_commitment_id uuid)
returns work_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_tenant uuid := current_tenant_id();
  v_item work_items;
  v_old commitments;
  v_c commitments;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  select * into v_item from work_items where id = p_work_item_id and tenant_id = v_tenant for update;
  if not found or v_item.status = 'CANCELLED' then
    raise exception 'work item not found';
  end if;

  if p_commitment_id is null then
    if v_item.commitment_id is null then
      return v_item;
    end if;
    select * into v_old from commitments where id = v_item.commitment_id;
    if v_old.owner_id is distinct from v_actor then
      raise exception 'not authorized to change this commitment';
    end if;
  else
    select * into v_c from commitments
     where id = p_commitment_id and tenant_id = v_tenant and archived_at is null;
    if not found then
      raise exception 'commitment not found';
    end if;
    if v_c.owner_id <> v_actor then
      raise exception 'not authorized to change this commitment';
    end if;
    if v_c.week_start < commitment_week() - 7 then
      raise exception 'commitment is closed';
    end if;
    if v_item.owner_id <> v_actor then
      raise exception 'only your own tasks can be linked';
    end if;
    if v_item.commitment_id = v_c.id then
      return v_item;
    end if;
    if v_item.commitment_id is not null then
      raise exception 'work item is linked to another commitment';
    end if;
    if (select count(*) from work_items where commitment_id = v_c.id and status <> 'CANCELLED') >= 10 then
      raise exception 'too many linked tasks';
    end if;
  end if;

  perform set_config('nusva.link_rpc', 'on', true);
  update work_items set commitment_id = p_commitment_id, updated_at = now()
   where id = v_item.id
  returning * into v_item;
  perform set_config('nusva.link_rpc', 'off', true);
  return v_item;
end;
$$;

create or replace function can_link_initiative(p_ini initiatives)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(current_worker_role() in ('executive', 'hc_admin')
      or p_ini.owner_id = current_worker_id()
      or p_ini.sponsor_id = current_worker_id(), false);
$$;

create or replace function set_work_item_initiative(p_work_item_id uuid, p_initiative_id uuid)
returns work_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_tenant uuid := current_tenant_id();
  v_item work_items;
  v_old initiatives;
  v_ini initiatives;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  select * into v_item from work_items where id = p_work_item_id and tenant_id = v_tenant for update;
  if not found or v_item.status = 'CANCELLED' then
    raise exception 'work item not found';
  end if;

  if p_initiative_id is null then
    if v_item.initiative_id is null then
      return v_item;
    end if;
    select * into v_old from initiatives where id = v_item.initiative_id;
    if not can_link_initiative(v_old) then
      raise exception 'not authorized to link tasks to this initiative';
    end if;
  else
    select * into v_ini from initiatives
     where id = p_initiative_id and tenant_id = v_tenant and archived_at is null;
    if not found then
      raise exception 'initiative not found';
    end if;
    if not can_link_initiative(v_ini) then
      raise exception 'not authorized to link tasks to this initiative';
    end if;
    if cardinality(v_ini.team_ids) > 0 and not (v_item.team_id = any(v_ini.team_ids)) then
      raise exception 'work item team is not in this initiative';
    end if;
    if v_item.initiative_id = v_ini.id then
      return v_item;
    end if;
    if v_item.initiative_id is not null then
      raise exception 'work item is linked to another initiative';
    end if;
    if (select count(*) from work_items where initiative_id = v_ini.id and status <> 'CANCELLED') >= 50 then
      raise exception 'too many linked tasks';
    end if;
  end if;

  perform set_config('nusva.link_rpc', 'on', true);
  update work_items set initiative_id = p_initiative_id, updated_at = now()
   where id = v_item.id
  returning * into v_item;
  perform set_config('nusva.link_rpc', 'off', true);
  return v_item;
end;
$$;

-- Lepas tautan saat komitmen diarsipkan.
create or replace function unlink_archived_commitment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.archived_at is not null and old.archived_at is null then
    perform set_config('nusva.link_rpc', 'on', true);
    update work_items set commitment_id = null, updated_at = now() where commitment_id = new.id;
    perform set_config('nusva.link_rpc', 'off', true);
  end if;
  return new;
end;
$$;

create trigger trg_unlink_archived_commitment
  after update of archived_at on commitments
  for each row execute function unlink_archived_commitment();

-- Lepas tautan saat inisiatif diarsipkan, atau saat outlet tugas keluar dari cakupan inisiatif.
create or replace function unlink_initiative_scope()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.archived_at is not null and old.archived_at is null then
    perform set_config('nusva.link_rpc', 'on', true);
    update work_items set initiative_id = null, updated_at = now() where initiative_id = new.id;
    perform set_config('nusva.link_rpc', 'off', true);
  elsif cardinality(new.team_ids) > 0 and new.team_ids is distinct from old.team_ids then
    perform set_config('nusva.link_rpc', 'on', true);
    update work_items set initiative_id = null, updated_at = now()
     where initiative_id = new.id and not (team_id = any(new.team_ids));
    perform set_config('nusva.link_rpc', 'off', true);
  end if;
  return new;
end;
$$;

create trigger trg_unlink_initiative_scope
  after update of archived_at, team_ids on initiatives
  for each row execute function unlink_initiative_scope();

revoke execute on function set_work_item_commitment(uuid, uuid) from public;
revoke execute on function set_work_item_commitment(uuid, uuid) from anon;
grant execute on function set_work_item_commitment(uuid, uuid) to authenticated;
revoke execute on function set_work_item_initiative(uuid, uuid) from public;
revoke execute on function set_work_item_initiative(uuid, uuid) from anon;
grant execute on function set_work_item_initiative(uuid, uuid) to authenticated;
revoke execute on function can_link_initiative(initiatives) from public;
revoke execute on function can_link_initiative(initiatives) from anon;
revoke execute on function unlink_archived_commitment() from public;
revoke execute on function unlink_archived_commitment() from anon;
revoke execute on function unlink_initiative_scope() from public;
revoke execute on function unlink_initiative_scope() from anon;
