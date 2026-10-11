-- 040: daftar KPI beserta bobotnya di setiap kotak Pohon KPI.
--
-- Satu kotak (posisi) sekarang berisi nama posisi, PIC, dan daftar KPI. Tiap KPI punya nama (wajib),
-- target (boleh kosong), dan bobot 1 sampai 100 (boleh kosong). Dibangun di atas migration 036:
-- 1. Kolom kpi_items jsonb pada kpi_nodes, selalu array, paling banyak 12 KPI per kotak. Hak baca
--    mengikuti policy kpi_nodes_select yang sudah ada (tidak ada policy baru).
-- 2. RPC save_kpi_node() versi baru dengan p_items (wajib, tanpa nilai bawaan, supaya tidak bentrok
--    dengan versi lama saat dipanggil lewat nama argumen). Aturannya sama dengan versi lama (hanya
--    manajer di tim sendiri, batas 6 tingkat dan 200 kotak) ditambah validasi daftar KPI di server:
--    nama wajib dan paling panjang 120 karakter, target paling panjang 200, bobot bilangan bulat 1
--    sampai 100, entri kosong tidak diterima. Jumlah bobot tidak dipaksa 100, hanya layar yang memberi tahu.
-- 3. Kolom lama (target, deadline, weight) tidak dihapus dan tidak disentuh oleh versi baru. Kotak
--    yang sudah punya target diisi satu KPI dari data itu (nama = target, bobot = bobot lama) supaya
--    isian yang sudah ditulis tidak hilang dari layar. Hanya kotak yang daftar KPI-nya masih kosong.
-- 4. Perubahan tercatat di audit_log lewat trigger yang sudah ada.
-- 5. Tidak ada DROP, REVOKE ALL, atau DELETE. Versi lama save_kpi_node() tetap ada supaya aplikasi
--    versi sebelumnya masih jalan sampai versi baru terpasang.

alter table kpi_nodes
  add column if not exists kpi_items jsonb not null default '[]'::jsonb;

alter table kpi_nodes
  add constraint kpi_nodes_items_check
  check (jsonb_typeof(kpi_items) = 'array' and jsonb_array_length(kpi_items) <= 12);

update kpi_nodes
   set kpi_items = jsonb_build_array(jsonb_build_object('name', left(target, 120), 'target', null, 'weight', weight))
 where kpi_items = '[]'::jsonb
   and target is not null;

create or replace function save_kpi_node(
  p_id uuid,
  p_parent_id uuid,
  p_position text,
  p_items jsonb,
  p_owner_id uuid default null,
  p_task text default null,
  p_tech_skill text default null,
  p_behavior_skill text default null,
  p_ai_assisted boolean default false
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
  v_owner_team uuid;
  v_depth integer;
  v_pos text := nullif(btrim(coalesce(p_position, '')), '');
  v_task text := nullif(btrim(coalesce(p_task, '')), '');
  v_tech text := nullif(btrim(coalesce(p_tech_skill, '')), '');
  v_beh text := nullif(btrim(coalesce(p_behavior_skill, '')), '');
  v_items jsonb := '[]'::jsonb;
  v_e jsonb;
  v_name text;
  v_tg text;
  v_w numeric;
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

  if v_pos is null then
    raise exception 'position is required';
  end if;
  if char_length(v_pos) > 120 or char_length(coalesce(v_task, '')) > 500
     or char_length(coalesce(v_tech, '')) > 200 or char_length(coalesce(v_beh, '')) > 200 then
    raise exception 'text is too long';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'invalid kpi items';
  end if;
  if jsonb_array_length(p_items) > 12 then
    raise exception 'too many kpi items';
  end if;
  for v_e in select e from jsonb_array_elements(p_items) as x(e) loop
    if jsonb_typeof(v_e) <> 'object' then
      raise exception 'invalid kpi items';
    end if;
    v_name := nullif(btrim(coalesce(v_e->>'name', '')), '');
    v_tg := nullif(btrim(coalesce(v_e->>'target', '')), '');
    if v_name is null then
      raise exception 'kpi item name is required';
    end if;
    if char_length(v_name) > 120 or char_length(coalesce(v_tg, '')) > 200 then
      raise exception 'text is too long';
    end if;
    v_w := null;
    if jsonb_typeof(v_e->'weight') = 'number' then
      v_w := (v_e->>'weight')::numeric;
      if v_w <> trunc(v_w) or v_w < 1 or v_w > 100 then
        raise exception 'invalid weight';
      end if;
    elsif v_e->'weight' is not null and jsonb_typeof(v_e->'weight') <> 'null' then
      raise exception 'invalid weight';
    end if;
    v_items := v_items || jsonb_build_array(jsonb_build_object('name', v_name, 'target', v_tg, 'weight', v_w));
  end loop;

  if p_owner_id is not null then
    select team_id into v_owner_team from workers where id = p_owner_id and tenant_id = v_tenant;
    if v_owner_team is distinct from v_team then
      raise exception 'not authorized to assign another team';
    end if;
  end if;

  if p_id is null then
    if p_parent_id is not null then
      select * into v_parent from kpi_nodes
       where id = p_parent_id and tenant_id = v_tenant and archived_at is null;
      if not found then
        raise exception 'kpi node not found';
      end if;
      if v_parent.team_id <> v_team then
        raise exception 'not authorized to edit the kpi tree';
      end if;
      with recursive anc as (
        select id, parent_id, 1 as d from kpi_nodes where id = p_parent_id
        union all
        select n.id, n.parent_id, anc.d + 1 from kpi_nodes n join anc on n.id = anc.parent_id
      )
      select max(d) into v_depth from anc;
      if v_depth >= 6 then
        raise exception 'kpi tree is too deep';
      end if;
    end if;
    if (select count(*) from kpi_nodes where team_id = v_team and archived_at is null) >= 200 then
      raise exception 'kpi tree is too large';
    end if;

    insert into kpi_nodes (tenant_id, team_id, parent_id, position_title, owner_id, task, kpi_items,
                           tech_skill, behavior_skill, ai_assisted, sort_order, created_by, updated_by)
    values (v_tenant, v_team, p_parent_id, v_pos, p_owner_id, v_task, v_items,
            v_tech, v_beh, coalesce(p_ai_assisted, false),
            coalesce((select max(sort_order) from kpi_nodes
                       where team_id = v_team and parent_id is not distinct from p_parent_id), 0) + 1,
            v_actor, v_actor)
    returning * into v_node;
  else
    select * into v_node from kpi_nodes
     where id = p_id and tenant_id = v_tenant and archived_at is null for update;
    if not found then
      raise exception 'kpi node not found';
    end if;
    if v_node.team_id <> v_team then
      raise exception 'not authorized to edit the kpi tree';
    end if;
    update kpi_nodes
       set position_title = v_pos,
           owner_id = p_owner_id,
           task = v_task,
           kpi_items = v_items,
           tech_skill = v_tech,
           behavior_skill = v_beh,
           ai_assisted = coalesce(p_ai_assisted, false),
           updated_by = v_actor,
           updated_at = now()
     where id = p_id
    returning * into v_node;
  end if;

  return v_node;
end;
$$;

revoke execute on function save_kpi_node(uuid, uuid, text, jsonb, uuid, text, text, text, boolean) from public;
revoke execute on function save_kpi_node(uuid, uuid, text, jsonb, uuid, text, text, text, boolean) from anon;
grant execute on function save_kpi_node(uuid, uuid, text, jsonb, uuid, text, text, text, boolean) to authenticated;
