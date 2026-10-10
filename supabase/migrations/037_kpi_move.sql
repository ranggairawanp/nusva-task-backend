-- 037: pindah induk dan ubah urutan kotak di pohon KPI.
--
-- RPC move_kpi_node(), hanya manajer di tim sendiri (aturan yang sama dengan save_kpi_node):
-- 1. p_direction 'up' atau 'down': tukar urutan dengan kotak sejajar di sebelahnya (induk sama).
--    Urutan kotak sejajar dirapikan dulu menjadi 1..n supaya tidak ada nilai kembar. Kalau sudah
--    di ujung, tidak ada yang berubah dan tidak ada galat.
-- 2. Tanpa arah: pindah ke induk lain (p_parent_id) atau ke posisi teratas (p_to_root = true),
--    ditaruh paling akhir di antara kotak sejajar barunya. Ditolak kalau induk baru tidak ada, beda
--    tim, kotak itu sendiri, atau salah satu bawahannya (akan membuat lingkaran), atau kalau
--    pohon hasilnya lebih dari 6 tingkat (kedalaman induk baru + tinggi cabang yang dipindah).
-- 3. Isian kotak tidak disentuh; yang berubah hanya parent_id, sort_order, updated_by, updated_at.
--    Perubahan tercatat di audit_log lewat trigger yang sudah ada.
-- 4. Tidak ada DROP, REVOKE ALL, atau DELETE.

create or replace function move_kpi_node(
  p_id uuid,
  p_parent_id uuid default null,
  p_direction text default null,
  p_to_root boolean default false
)
returns kpi_nodes
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_role text := current_worker_role();
  v_tenant uuid := current_tenant_id();
  v_team uuid;
  v_node kpi_nodes;
  v_parent kpi_nodes;
  v_other kpi_nodes;
  v_depth integer;
  v_height integer;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  if v_role is distinct from 'manager' then
    raise exception 'not authorized to edit the kpi tree';
  end if;
  select team_id into v_team from workers where id = v_actor;
  if v_team is null then
    raise exception 'not authorized to edit the kpi tree';
  end if;

  select * into v_node from kpi_nodes
   where id = p_id and tenant_id = v_tenant and archived_at is null for update;
  if not found then
    raise exception 'kpi node not found';
  end if;
  if v_node.team_id <> v_team then
    raise exception 'not authorized to edit the kpi tree';
  end if;

  if p_direction is not null then
    if p_direction not in ('up', 'down') then
      raise exception 'invalid move';
    end if;
    -- rapikan urutan kotak sejajar menjadi 1..n
    with ranked as (
      select id, row_number() over (order by sort_order, created_at, id) as rn
        from kpi_nodes
       where team_id = v_team and archived_at is null
         and parent_id is not distinct from v_node.parent_id
    )
    update kpi_nodes k set sort_order = r.rn
      from ranked r where k.id = r.id and k.sort_order is distinct from r.rn;
    select * into v_node from kpi_nodes where id = p_id;

    if p_direction = 'up' then
      select * into v_other from kpi_nodes
       where team_id = v_team and archived_at is null
         and parent_id is not distinct from v_node.parent_id and sort_order = v_node.sort_order - 1;
    else
      select * into v_other from kpi_nodes
       where team_id = v_team and archived_at is null
         and parent_id is not distinct from v_node.parent_id and sort_order = v_node.sort_order + 1;
    end if;
    if found then
      update kpi_nodes set sort_order = v_other.sort_order, updated_by = v_actor, updated_at = now() where id = v_node.id;
      update kpi_nodes set sort_order = v_node.sort_order, updated_by = v_actor, updated_at = now() where id = v_other.id;
    end if;
    select * into v_node from kpi_nodes where id = p_id;
    return v_node;
  end if;

  if p_parent_id is null and not coalesce(p_to_root, false) then
    raise exception 'invalid move';
  end if;
  if p_parent_id is not null then
    if p_parent_id = p_id then
      raise exception 'invalid move';
    end if;
    select * into v_parent from kpi_nodes
     where id = p_parent_id and tenant_id = v_tenant and archived_at is null;
    if not found then
      raise exception 'kpi node not found';
    end if;
    if v_parent.team_id <> v_team then
      raise exception 'not authorized to edit the kpi tree';
    end if;
    -- induk baru tidak boleh bawahan dari kotak ini (lingkaran)
    if exists (
      with recursive anc as (
        select id, parent_id from kpi_nodes where id = p_parent_id
        union all
        select n.id, n.parent_id from kpi_nodes n join anc on n.id = anc.parent_id
      )
      select 1 from anc where id = p_id
    ) then
      raise exception 'invalid move';
    end if;
    with recursive anc as (
      select id, parent_id, 1 as d from kpi_nodes where id = p_parent_id
      union all
      select n.id, n.parent_id, anc.d + 1 from kpi_nodes n join anc on n.id = anc.parent_id
    )
    select max(d) into v_depth from anc;
  else
    v_depth := 0;
  end if;

  with recursive sub as (
    select id, 1 as h from kpi_nodes where id = p_id
    union all
    select n.id, sub.h + 1 from kpi_nodes n join sub on n.parent_id = sub.id where n.archived_at is null
  )
  select max(h) into v_height from sub;
  if v_depth + v_height > 6 then
    raise exception 'kpi tree is too deep';
  end if;

  update kpi_nodes
     set parent_id = p_parent_id,
         sort_order = coalesce((select max(sort_order) from kpi_nodes
                                 where team_id = v_team and archived_at is null
                                   and parent_id is not distinct from p_parent_id and id <> p_id), 0) + 1,
         updated_by = v_actor,
         updated_at = now()
   where id = p_id
  returning * into v_node;

  return v_node;
end;
$$;

revoke execute on function move_kpi_node(uuid, uuid, text, boolean) from public;
revoke execute on function move_kpi_node(uuid, uuid, text, boolean) from anon;
grant execute on function move_kpi_node(uuid, uuid, text, boolean) to authenticated;
