-- 042: ketergantungan antartugas ("tugas ini menunggu tugas lain").
--
-- Tabel dependencies sudah ada sejak 003 (beserta penolak lingkaran 004), tapi belum punya jalur tulis.
-- Migration ini memberinya jalur tulis yang dijaga server:
-- 1. Hanya satu arti yang dipakai: DEPENDS_ON, dari tugas yang menunggu (from) ke tugas yang ditunggu (to).
--    BLOCKS adalah kebalikannya, jadi tidak ditulis supaya satu hubungan tidak tercatat dua kali.
-- 2. Hapus berupa arsip (removed_at, removed_by), bukan DELETE, supaya riwayatnya tetap ada. Menambah lagi
--    hubungan yang pernah diarsipkan menghidupkan baris lamanya (unik per pasangan dan jenis).
-- 3. Penolak lingkaran 004 diganti: hanya menghitung hubungan aktif, juga berjalan saat baris dihidupkan lagi,
--    dan tugas yang menunggu dirinya sendiri ditolak lewat check constraint.
-- 4. RPC add_work_item_dependency() dan remove_work_item_dependency(): hak ubahnya sama dengan mengubah tugas
--    yang menunggu (pemilik, manajer tim tugas itu, atau eksekutif/HC; can_manage_work_item). Tugas yang
--    ditunggu boleh dari tim lain di tenant yang sama (misalnya kiriman gudang pusat). Tugas selesai atau
--    dibatalkan tidak bisa diberi ketergantungan baru, tugas yang dibatalkan tidak bisa ditunggu, dan satu
--    tugas paling banyak menunggu 10 tugas aktif.
-- 5. Ketergantungan hanya informasi: tugas tetap bisa diselesaikan walau tugas yang ditunggu belum selesai.
--    Status tugas tidak diubah otomatis.
-- 6. Setiap perubahan tercatat di audit_log lewat log_audit_event() (010). Tabel tetap hanya punya policy
--    SELECT seluas tenant; semua tulisan lewat fungsi.
-- 7. Tidak ada DROP, REVOKE ALL, atau DELETE.

alter table dependencies
  add column if not exists created_by uuid references workers(id),
  add column if not exists removed_at timestamptz,
  add column if not exists removed_by uuid references workers(id);

alter table dependencies
  add constraint dependencies_not_self check (from_work_item_id <> to_work_item_id);

create or replace function reject_circular_dependency()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.removed_at is not null then
    return new;
  end if;
  if exists (
    with recursive chain as (
      select to_work_item_id from dependencies
       where from_work_item_id = new.to_work_item_id and removed_at is null and id <> new.id
      union
      select d.to_work_item_id from dependencies d
        join chain c on d.from_work_item_id = c.to_work_item_id
       where d.removed_at is null and d.id <> new.id
    )
    select 1 from chain where to_work_item_id = new.from_work_item_id
  ) then
    raise exception 'circular dependency rejected';
  end if;
  return new;
end;
$$;

create trigger trg_reject_circular_dependency_revive
  before update of removed_at on dependencies
  for each row execute function reject_circular_dependency();

create trigger trg_audit_dependencies
  after insert or update or delete on dependencies
  for each row execute function log_audit_event();

create or replace function add_work_item_dependency(p_work_item_id uuid, p_depends_on_id uuid)
returns dependencies
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_tenant uuid := current_tenant_id();
  v_item work_items;
  v_target work_items;
  v_dep dependencies;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  select * into v_item from work_items where id = p_work_item_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'work item not found';
  end if;
  if not can_manage_work_item(v_item.owner_id, v_item.team_id) then
    raise exception 'not authorized to change this work item';
  end if;
  if v_item.status in ('DONE', 'CANCELLED') then
    raise exception 'cannot edit a finished work item';
  end if;
  if p_depends_on_id = p_work_item_id then
    raise exception 'work item cannot depend on itself';
  end if;
  select * into v_target from work_items where id = p_depends_on_id and tenant_id = v_tenant;
  if not found then
    raise exception 'work item not found';
  end if;
  if v_target.status = 'CANCELLED' then
    raise exception 'cannot depend on a cancelled work item';
  end if;
  if (select count(*) from dependencies
       where from_work_item_id = p_work_item_id and kind = 'DEPENDS_ON' and removed_at is null) >= 10 then
    raise exception 'too many dependencies';
  end if;

  select * into v_dep from dependencies
   where from_work_item_id = p_work_item_id and to_work_item_id = p_depends_on_id and kind = 'DEPENDS_ON';
  if found then
    if v_dep.removed_at is null then
      raise exception 'dependency already exists';
    end if;
    update dependencies
       set removed_at = null, removed_by = null, created_by = v_actor, created_at = now()
     where id = v_dep.id
    returning * into v_dep;
    return v_dep;
  end if;

  insert into dependencies (tenant_id, from_work_item_id, to_work_item_id, kind, created_by)
  values (v_tenant, p_work_item_id, p_depends_on_id, 'DEPENDS_ON', v_actor)
  returning * into v_dep;
  return v_dep;
end;
$$;

create or replace function remove_work_item_dependency(p_id uuid)
returns dependencies
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_tenant uuid := current_tenant_id();
  v_dep dependencies;
  v_item work_items;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  select * into v_dep from dependencies where id = p_id and tenant_id = v_tenant and removed_at is null for update;
  if not found then
    raise exception 'dependency not found';
  end if;
  select * into v_item from work_items where id = v_dep.from_work_item_id;
  if not can_manage_work_item(v_item.owner_id, v_item.team_id) then
    raise exception 'not authorized to change this work item';
  end if;
  update dependencies set removed_at = now(), removed_by = v_actor where id = p_id
  returning * into v_dep;
  return v_dep;
end;
$$;

revoke execute on function add_work_item_dependency(uuid, uuid) from public;
revoke execute on function add_work_item_dependency(uuid, uuid) from anon;
grant execute on function add_work_item_dependency(uuid, uuid) to authenticated;
revoke execute on function remove_work_item_dependency(uuid) from public;
revoke execute on function remove_work_item_dependency(uuid) from anon;
grant execute on function remove_work_item_dependency(uuid) to authenticated;
