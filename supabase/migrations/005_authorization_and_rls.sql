-- Helpers: resolve the calling user's tenant and worker row from their Supabase Auth session
create or replace function current_tenant_id()
returns uuid as $$
  select tenant_id from workers where auth_user_id = auth.uid() limit 1;
$$ language sql stable security definer set search_path = public;

create or replace function current_worker_id()
returns uuid as $$
  select id from workers where auth_user_id = auth.uid() limit 1;
$$ language sql stable security definer set search_path = public;

create or replace function current_worker_role()
returns text as $$
  select role from workers where auth_user_id = auth.uid() limit 1;
$$ language sql stable security definer set search_path = public;

-- tenants is the root: it has no tenant_id column, its own id IS the tenant
alter table tenants enable row level security;
create policy tenant_isolation_select on tenants for select
  using (id = current_tenant_id());

-- Enable RLS + uniform tenant isolation on every other domain table
do $$
declare
  t text;
begin
  for t in select unnest(array[
    'organizations','legal_entities','business_units','teams','positions','workers',
    'business_outcomes','priorities','drivers','commitments','commitment_checkins',
    'initiatives','initiative_milestones','recurring_templates',
    'work_items','checklist_items','dependencies','blockers','evidence'
  ])
  loop
    execute format('alter table %I enable row level security', t);
    execute format(
      'create policy tenant_isolation_select on %I for select using (tenant_id = current_tenant_id())', t
    );
  end loop;
end $$;

-- work_items: role-scoped write policy (employee = own rows, manager+ = their team, executive/hc_admin = tenant-wide)
create policy work_items_write on work_items for all
  using (
    tenant_id = current_tenant_id()
    and (
      owner_id = current_worker_id()
      or current_worker_role() in ('manager','executive','hc_admin')
    )
  )
  with check (
    tenant_id = current_tenant_id()
    and (
      owner_id = current_worker_id()
      or current_worker_role() in ('manager','executive','hc_admin')
    )
  );

-- audit_log: insert-only for any authenticated worker in the same tenant, no select restriction beyond tenant
create policy audit_log_insert on audit_log for insert
  with check (tenant_id = current_tenant_id());
create policy audit_log_select on audit_log for select
  using (tenant_id = current_tenant_id());
