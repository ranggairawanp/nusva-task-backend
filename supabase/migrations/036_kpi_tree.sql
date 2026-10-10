-- 036: Pohon KPI per tim, disusun manajer seperti org chart.
--
-- Satu kotak (kpi_nodes) mewakili satu posisi: tugas, target, deadline, bobot skor (1 sampai 100,
-- boleh kosong), skill teknik dan skill perilaku (keduanya boleh kosong), dan kotak induknya.
-- Kotak tanpa induk adalah akar pohon tim. Pohon terpisah dari Prioritas Utama, Action Plan, dan
-- tugas: tidak ada angka yang ditarik dari work_items di sini.
--
-- Keputusan desain:
-- 1. Baca per peran, dipaksa di policy: eksekutif dan HC melihat seluruh tenant, manajer melihat
--    pohon timnya sendiri, karyawan hanya kotak yang menunjuk dirinya sebagai penanggung jawab
--    ditambah rantai atasannya sampai akar (kpi_visible_ids()).
-- 2. Tulis hanya lewat RPC save_kpi_node() dan archive_kpi_node(), hanya oleh manajer di tim
--    sendiri. Tabel hanya punya policy SELECT. Eksekutif dan HC tidak menulis di versi ini.
-- 3. Keputusan tetap di manusia: saran AI tidak pernah disimpan sendiri. Kolom ai_assisted hanya
--    penanda jujur bahwa manajer memakai saran Nexa pada kotak itu, dikirim aplikasi setelah
--    manajer menekan Simpan.
-- 4. Bobot tidak dipaksa berjumlah 100: aplikasi menampilkan jumlah bobot saudara sebagai
--    informasi. Yang belum diisi tetap null, bukan nol.
-- 5. Batas: kedalaman 6 tingkat, 200 kotak aktif per tim, supaya kanvas tetap terbaca.
-- 6. Kotak tidak dihapus: archive_kpi_node() mengisi archived_at pada kotak itu beserta seluruh
--    bawahannya, dan kotak terarsip tidak terbaca lagi lewat policy.
-- 7. Perubahan tercatat di audit_log lewat trigger log_audit_event (migration 010).
-- 8. Tidak ada DROP, REVOKE ALL, atau DELETE.

create table kpi_nodes (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  team_id uuid not null references teams(id),
  parent_id uuid references kpi_nodes(id),
  position_title text not null check (char_length(position_title) between 1 and 120),
  owner_id uuid references workers(id),
  task text check (task is null or char_length(task) between 1 and 500),
  target text check (target is null or char_length(target) between 1 and 200),
  deadline date,
  weight smallint check (weight is null or weight between 1 and 100),
  tech_skill text check (tech_skill is null or char_length(tech_skill) between 1 and 200),
  behavior_skill text check (behavior_skill is null or char_length(behavior_skill) between 1 and 200),
  ai_assisted boolean not null default false,
  sort_order integer not null default 0,
  archived_at timestamptz,
  created_by uuid references workers(id),
  created_at timestamptz not null default now(),
  updated_by uuid references workers(id),
  updated_at timestamptz not null default now()
);
create index kpi_nodes_team_idx on kpi_nodes (team_id, parent_id) where archived_at is null;
create index kpi_nodes_owner_idx on kpi_nodes (owner_id) where archived_at is null;
alter table kpi_nodes enable row level security;
grant select on kpi_nodes to authenticated;

create trigger trg_audit_kpi_nodes after insert or update or delete on kpi_nodes
  for each row execute function log_audit_event();

-- Kotak milik pemanggil beserta seluruh atasannya sampai akar. Dipakai policy baca karyawan.
create or replace function kpi_visible_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  with recursive up as (
    select id, parent_id from kpi_nodes
     where owner_id = current_worker_id() and archived_at is null and tenant_id = current_tenant_id()
    union
    select n.id, n.parent_id from kpi_nodes n join up on n.id = up.parent_id
     where n.archived_at is null
  )
  select id from up;
$$;
revoke execute on function kpi_visible_ids() from public;
revoke execute on function kpi_visible_ids() from anon;
grant execute on function kpi_visible_ids() to authenticated;

create policy kpi_nodes_select on kpi_nodes for select
  using (
    tenant_id = current_tenant_id()
    and archived_at is null
    and (
      current_worker_role() in ('executive', 'hc_admin')
      or (current_worker_role() = 'manager'
          and team_id = (select team_id from workers where id = current_worker_id()))
      or id in (select kpi_visible_ids())
    )
  );

create or replace function save_kpi_node(
  p_id uuid,
  p_parent_id uuid,
  p_position text,
  p_owner_id uuid default null,
  p_task text default null,
  p_target text default null,
  p_deadline date default null,
  p_weight integer default null,
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
  v_target text := nullif(btrim(coalesce(p_target, '')), '');
  v_tech text := nullif(btrim(coalesce(p_tech_skill, '')), '');
  v_beh text := nullif(btrim(coalesce(p_behavior_skill, '')), '');
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
     or char_length(coalesce(v_target, '')) > 200 or char_length(coalesce(v_tech, '')) > 200
     or char_length(coalesce(v_beh, '')) > 200 then
    raise exception 'text is too long';
  end if;
  if p_weight is not null and (p_weight < 1 or p_weight > 100) then
    raise exception 'invalid weight';
  end if;

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

    insert into kpi_nodes (tenant_id, team_id, parent_id, position_title, owner_id, task, target, deadline,
                           weight, tech_skill, behavior_skill, ai_assisted, sort_order, created_by, updated_by)
    values (v_tenant, v_team, p_parent_id, v_pos, p_owner_id, v_task, v_target, p_deadline,
            p_weight, v_tech, v_beh, coalesce(p_ai_assisted, false),
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
           target = v_target,
           deadline = p_deadline,
           weight = p_weight,
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

revoke execute on function save_kpi_node(uuid, uuid, text, uuid, text, text, date, integer, text, text, boolean) from public;
revoke execute on function save_kpi_node(uuid, uuid, text, uuid, text, text, date, integer, text, text, boolean) from anon;
grant execute on function save_kpi_node(uuid, uuid, text, uuid, text, text, date, integer, text, text, boolean) to authenticated;

-- Mengarsipkan satu kotak beserta seluruh bawahannya. Mengembalikan jumlah kotak yang diarsipkan.
create or replace function archive_kpi_node(p_id uuid)
returns integer
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
  v_count integer;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  if v_role is distinct from 'manager' then
    raise exception 'not authorized to edit the kpi tree';
  end if;
  select team_id into v_team from workers where id = v_actor;

  select * into v_node from kpi_nodes
   where id = p_id and tenant_id = v_tenant and archived_at is null for update;
  if not found then
    raise exception 'kpi node not found';
  end if;
  if v_node.team_id is distinct from v_team then
    raise exception 'not authorized to edit the kpi tree';
  end if;

  with recursive sub as (
    select id from kpi_nodes where id = p_id
    union
    select n.id from kpi_nodes n join sub on n.parent_id = sub.id where n.archived_at is null
  ),
  upd as (
    update kpi_nodes set archived_at = now(), updated_by = v_actor, updated_at = now()
     where id in (select id from sub) and archived_at is null
    returning 1
  )
  select count(*) into v_count from upd;

  return v_count;
end;
$$;

revoke execute on function archive_kpi_node(uuid) from public;
revoke execute on function archive_kpi_node(uuid) from anon;
grant execute on function archive_kpi_node(uuid) to authenticated;
