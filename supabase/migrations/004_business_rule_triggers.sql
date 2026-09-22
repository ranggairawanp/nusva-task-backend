-- 7-state Work Item transition guard
create or replace function validate_work_item_transition()
returns trigger as $$
begin
  if old.status = 'DONE' and new.status <> 'DONE' then
    raise exception 'cannot reopen a DONE work item directly';
  end if;
  if old.status = 'CANCELLED' then
    raise exception 'cannot transition out of CANCELLED';
  end if;
  new.updated_at := now();
  return new;
end;
$$ language plpgsql;

create trigger trg_work_item_transition
  before update on work_items
  for each row execute function validate_work_item_transition();

-- Circular dependency guard (WM-BR-007)
create or replace function reject_circular_dependency()
returns trigger as $$
begin
  if exists (
    with recursive chain as (
      select to_work_item_id from dependencies where from_work_item_id = new.to_work_item_id
      union all
      select d.to_work_item_id from dependencies d
      join chain c on d.from_work_item_id = c.to_work_item_id
    )
    select 1 from chain where to_work_item_id = new.from_work_item_id
  ) then
    raise exception 'circular dependency rejected';
  end if;
  return new;
end;
$$ language plpgsql;

create trigger trg_reject_circular_dependency
  before insert on dependencies
  for each row execute function reject_circular_dependency();

-- Max 2 active Priorities per team (replaces the console.assert no-op)
create or replace function enforce_priority_cap()
returns trigger as $$
begin
  if (select count(*) from priorities
      where team_id = new.team_id
        and status not in ('CLOSED','CANCELLED')
        and id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid)) >= 2
  then
    raise exception 'a team may not have more than 2 active priorities';
  end if;
  return new;
end;
$$ language plpgsql;

create trigger trg_enforce_priority_cap
  before insert or update on priorities
  for each row execute function enforce_priority_cap();

-- Max 3 Drivers per Priority
create or replace function enforce_driver_cap()
returns trigger as $$
begin
  if (select count(*) from drivers
      where priority_id = new.priority_id
        and id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid)) >= 3
  then
    raise exception 'a priority may not have more than 3 drivers';
  end if;
  return new;
end;
$$ language plpgsql;

create trigger trg_enforce_driver_cap
  before insert on drivers
  for each row execute function enforce_driver_cap();

-- audit_log is append-only: no update or delete, by any role
alter table audit_log enable row level security;
revoke update, delete on audit_log from public, anon, authenticated;
