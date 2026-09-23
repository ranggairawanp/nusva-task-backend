-- API layer, Phase 1.
--
-- Plain reads and simple single-table edits are already served by Supabase's
-- auto-generated REST API (PostgREST) under RLS: GET/PATCH on
-- /rest/v1/work_items, /rest/v1/priorities, etc. No custom code is needed
-- for those, and none is added here.
--
-- What RLS alone cannot express safely is the small set of actions that
-- touch more than one table at once, per CLAUDE.md's WORK -> PERFORMANCE
-- model ("task ditandai selesai -> evidence/actual pada Aksi Penggerak,
-- senyap di belakang layar"): completing a Work Item must also write
-- Evidence and, if the item is tied to a Driver, bump that Driver's
-- `actual` -- as one transaction, and never as a bare client PATCH to
-- drivers.actual (which is why drivers has no write policy at all: the
-- only way `actual` moves is through this function). The same applies to
-- raising or resolving a Blocker, which must also flip the parent Work
-- Item's status.
--
-- These are Postgres functions (RPC), not Edge Functions: the logic is
-- pure SQL/plpgsql over this database, so a transactional SQL function
-- exposed by PostgREST at /rest/v1/rpc/<name> is the right fit; an Edge
-- Function would only earn its keep once this needs to call something
-- outside Postgres (e.g. a push notification), which is out of Phase 1
-- scope.
--
-- All three are SECURITY DEFINER (so they can write to drivers/evidence,
-- which the caller has no direct RLS write access to) and therefore check
-- authorization by hand, mirroring the work_items_write policy's rule
-- (owner, or manager/executive/hc_admin) instead of relying on RLS.

create or replace function complete_work_item(p_work_item_id uuid)
returns work_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item work_items;
  v_actor uuid := current_worker_id();
  v_role text := current_worker_role();
begin
  select * into v_item from work_items
    where id = p_work_item_id and tenant_id = current_tenant_id();
  if v_item.id is null then
    raise exception 'work item not found';
  end if;
  if not (v_item.owner_id = v_actor or v_role in ('manager','executive','hc_admin')) then
    raise exception 'not authorized to complete this work item';
  end if;

  update work_items set status = 'DONE'
    where id = p_work_item_id
    returning * into v_item;

  insert into evidence (tenant_id, work_item_id, type, payload, created_by)
  values (v_item.tenant_id, v_item.id, 'SYSTEM_EVENT',
          jsonb_build_object('event', 'work_item_completed', 'at', now()), v_actor);

  if v_item.driver_id is not null and v_item.qty is not null then
    update drivers set actual = actual + v_item.qty, version = version + 1
      where id = v_item.driver_id;
  end if;

  return v_item;
end;
$$;

revoke execute on function complete_work_item(uuid) from public;
grant execute on function complete_work_item(uuid) to authenticated;

create or replace function raise_blocker(p_work_item_id uuid, p_reason text)
returns blockers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item work_items;
  v_actor uuid := current_worker_id();
  v_role text := current_worker_role();
  v_blocker blockers;
begin
  select * into v_item from work_items
    where id = p_work_item_id and tenant_id = current_tenant_id();
  if v_item.id is null then
    raise exception 'work item not found';
  end if;
  if not (v_item.owner_id = v_actor or v_role in ('manager','executive','hc_admin')) then
    raise exception 'not authorized to raise a blocker on this work item';
  end if;

  update work_items set status = 'BLOCKED' where id = p_work_item_id;

  insert into blockers (tenant_id, work_item_id, reason, raised_by, status)
  values (v_item.tenant_id, p_work_item_id, p_reason, v_actor, 'OPEN')
  returning * into v_blocker;

  return v_blocker;
end;
$$;

revoke execute on function raise_blocker(uuid, text) from public;
grant execute on function raise_blocker(uuid, text) to authenticated;

create or replace function resolve_blocker(p_blocker_id uuid)
returns blockers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_blocker blockers;
  v_item work_items;
  v_actor uuid := current_worker_id();
  v_role text := current_worker_role();
  v_open_remaining int;
begin
  select * into v_blocker from blockers
    where id = p_blocker_id and tenant_id = current_tenant_id();
  if v_blocker.id is null then
    raise exception 'blocker not found';
  end if;

  select * into v_item from work_items where id = v_blocker.work_item_id;
  if not (v_item.owner_id = v_actor or v_role in ('manager','executive','hc_admin')) then
    raise exception 'not authorized to resolve this blocker';
  end if;

  update blockers set status = 'RESOLVED', resolved_at = now()
    where id = p_blocker_id
    returning * into v_blocker;

  select count(*) into v_open_remaining from blockers
    where work_item_id = v_item.id and status = 'OPEN';

  if v_open_remaining = 0 and v_item.status = 'BLOCKED' then
    update work_items set status = 'READY' where id = v_item.id;
  end if;

  return v_blocker;
end;
$$;

revoke execute on function resolve_blocker(uuid) from public;
grant execute on function resolve_blocker(uuid) to authenticated;

-- checklist_items had only the generic tenant-wide SELECT policy; add
-- ownership-scoped write access (same rule as work_items_write), routed
-- through the parent Work Item since checklist_items carries no owner_id
-- of its own. A plain PATCH to /rest/v1/checklist_items now works for the
-- item's owner or a manager+, no RPC needed for something this simple.
create policy checklist_items_write on checklist_items for all
  using (
    tenant_id = current_tenant_id()
    and exists (
      select 1 from work_items w
      where w.id = checklist_items.work_item_id
        and (w.owner_id = current_worker_id() or current_worker_role() in ('manager','executive','hc_admin'))
    )
  )
  with check (
    tenant_id = current_tenant_id()
    and exists (
      select 1 from work_items w
      where w.id = checklist_items.work_item_id
        and (w.owner_id = current_worker_id() or current_worker_role() in ('manager','executive','hc_admin'))
    )
  );

-- evidence had only the generic SELECT policy. Unlike drivers, manual
-- evidence (ATTACHMENT/LINK/NOTE, e.g. a photo attached mid-task) is a
-- legitimate direct write, not only a side effect of completing a task --
-- so it gets a real insert policy rather than being funneled through a
-- function. Self-attributed only, append-only (no update/delete policy).
create policy evidence_insert on evidence for insert
  with check (
    tenant_id = current_tenant_id()
    and created_by = current_worker_id()
  );

-- Generic audit trail: every insert/update/delete on the core domain
-- tables is now recorded in audit_log (id, actor, before/after), the
-- table that migration 004 already made append-only but that nothing
-- wrote to until now.
create or replace function log_audit_event()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
begin
  if v_actor is null then
    return coalesce(new, old);
  end if;
  insert into audit_log (tenant_id, actor_id, action, object_type, object_id, before, after)
  values (
    coalesce(new.tenant_id, old.tenant_id),
    v_actor,
    tg_op,
    tg_table_name,
    coalesce(new.id, old.id),
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end
  );
  return coalesce(new, old);
end;
$$;

create trigger trg_audit_work_items after insert or update or delete on work_items for each row execute function log_audit_event();
create trigger trg_audit_priorities after insert or update or delete on priorities for each row execute function log_audit_event();
create trigger trg_audit_drivers after insert or update or delete on drivers for each row execute function log_audit_event();
create trigger trg_audit_checklist_items after insert or update or delete on checklist_items for each row execute function log_audit_event();
create trigger trg_audit_blockers after insert or update or delete on blockers for each row execute function log_audit_event();
create trigger trg_audit_business_outcomes after insert or update or delete on business_outcomes for each row execute function log_audit_event();
