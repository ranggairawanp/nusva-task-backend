-- Quick add (Pekerjaan Saya / Board Tim) had no live-mode equivalent: the
-- frontend button showed a toast instead, because no RPC existed for it
-- (see nusvapeople-task CLAUDE.md's "Koneksi backend" section and this
-- repo's README). This is the RPC that closes that gap.
--
-- Why an RPC and not a bare client INSERT under the existing work_items_write
-- RLS policy (which already permits it): that policy's `with check` only
-- validates owner_id, not creator_id, so a client-side INSERT could set
-- creator_id to anything. It also leaves the client responsible for knowing
-- the right team_id, which it has no legitimate way to look up (workers has
-- no read policy of its own beyond the current_worker_*() helpers). This
-- function derives both server-side from the target owner's own worker row,
-- the same "caller identity, not caller-supplied IDs" shape as the other
-- three RPCs in migration 010.
--
-- Quick add in the existing static prototype (data.js-backed addTask()) only
-- ever creates a routine, non-priority task: no priority_id/driver_id, lane
-- 'routine'. This RPC keeps that scope; a priority-linked Work Item is a
-- PERFORMANCE-world decision (CLAUDE.md's WORK/PERFORMANCE split) that a
-- quick add was never meant to make, live or static.

create or replace function create_work_item(
  p_title_id text,
  p_title_en text,
  p_due_at timestamptz,
  p_priority_level text default 'NORMAL',
  p_owner_id uuid default null
)
returns work_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_role text := current_worker_role();
  v_tenant uuid := current_tenant_id();
  v_owner uuid := coalesce(p_owner_id, v_actor);
  v_team uuid;
  v_item work_items;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  if p_title_id is null or btrim(p_title_id) = '' then
    raise exception 'title is required';
  end if;
  if p_due_at is null then
    raise exception 'due date is required';
  end if;
  if p_owner_id is not null and p_owner_id <> v_actor and v_role not in ('manager','executive','hc_admin') then
    raise exception 'not authorized to assign work to another worker';
  end if;

  select team_id into v_team from workers where id = v_owner and tenant_id = v_tenant;
  if v_team is null then
    raise exception 'owner has no team to create this work item in';
  end if;

  insert into work_items (tenant_id, team_id, type, title, creator_id, owner_id, status, priority_level, due_at)
  values (
    v_tenant, v_team, 'TASK',
    jsonb_build_object('id', p_title_id, 'en', coalesce(nullif(btrim(p_title_en), ''), p_title_id)),
    v_actor, v_owner, 'READY', p_priority_level, p_due_at
  )
  returning * into v_item;

  return v_item;
end;
$$;

revoke execute on function create_work_item(text, text, timestamptz, text, uuid) from public;
revoke execute on function create_work_item(text, text, timestamptz, text, uuid) from anon;
grant execute on function create_work_item(text, text, timestamptz, text, uuid) to authenticated;
