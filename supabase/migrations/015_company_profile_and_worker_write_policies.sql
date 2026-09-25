-- Write access for company profile data (tenant -> organization -> legal
-- entity -> business unit -> team -> position) and for editing existing
-- worker rows, so the frontend can stop treating this hierarchy as
-- read-only seed data. Creating a NEW worker (a real login account) is
-- deliberately NOT granted here: that needs a service-role Edge Function,
-- because it has to call auth.admin.createUser before any workers row can
-- legally exist (workers.auth_user_id is a not-null FK to auth.users).
--
-- Scope split mirrors the existing work_items_write pattern already in
-- migration 005: manager = their own team, executive/hc_admin = tenant-wide.
-- Company-wide identity (tenant/organization/legal_entity/business_unit)
-- is leadership-only (executive/hc_admin): a single outlet manager should
-- not be able to rename the legal entity or add a whole new business unit.
-- Team/position edits within a manager's own team stay manager-writable;
-- creating a brand new team or position is still leadership-only, so a
-- manager cannot spin up new organizational structure unilaterally.

create policy tenants_write on tenants for update
  using (id = current_tenant_id() and current_worker_role() in ('executive', 'hc_admin'))
  with check (id = current_tenant_id() and current_worker_role() in ('executive', 'hc_admin'));

create policy organizations_write on organizations for update
  using (tenant_id = current_tenant_id() and current_worker_role() in ('executive', 'hc_admin'))
  with check (tenant_id = current_tenant_id() and current_worker_role() in ('executive', 'hc_admin'));

create policy legal_entities_write on legal_entities for update
  using (tenant_id = current_tenant_id() and current_worker_role() in ('executive', 'hc_admin'))
  with check (tenant_id = current_tenant_id() and current_worker_role() in ('executive', 'hc_admin'));

create policy business_units_write on business_units for update
  using (tenant_id = current_tenant_id() and current_worker_role() in ('executive', 'hc_admin'))
  with check (tenant_id = current_tenant_id() and current_worker_role() in ('executive', 'hc_admin'));

create policy teams_write on teams for update
  using (
    tenant_id = current_tenant_id()
    and (
      (current_worker_role() = 'manager' and id = (select team_id from workers where id = current_worker_id()))
      or current_worker_role() in ('executive', 'hc_admin')
    )
  )
  with check (
    tenant_id = current_tenant_id()
    and (
      (current_worker_role() = 'manager' and id = (select team_id from workers where id = current_worker_id()))
      or current_worker_role() in ('executive', 'hc_admin')
    )
  );

create policy teams_insert on teams for insert
  with check (tenant_id = current_tenant_id() and current_worker_role() in ('executive', 'hc_admin'));

create policy positions_write on positions for update
  using (
    tenant_id = current_tenant_id()
    and (
      (current_worker_role() = 'manager' and team_id = (select team_id from workers where id = current_worker_id()))
      or current_worker_role() in ('executive', 'hc_admin')
    )
  )
  with check (
    tenant_id = current_tenant_id()
    and (
      (current_worker_role() = 'manager' and team_id = (select team_id from workers where id = current_worker_id()))
      or current_worker_role() in ('executive', 'hc_admin')
    )
  );

create policy positions_insert on positions for insert
  with check (
    tenant_id = current_tenant_id()
    and (
      (current_worker_role() = 'manager' and team_id = (select team_id from workers where id = current_worker_id()))
      or current_worker_role() in ('executive', 'hc_admin')
    )
  );

-- Editing an existing worker (name, role, team/position reassignment) stays
-- leadership-only: RLS is row-level, not column-level, so a policy that let
-- a manager update "their own team's workers" would also let that manager
-- promote one of their reports to executive. Role changes go through
-- executive/hc_admin only until there is a real column-level or trigger-based
-- guard against role escalation.
create policy workers_write on workers for update
  using (tenant_id = current_tenant_id() and current_worker_role() in ('executive', 'hc_admin'))
  with check (tenant_id = current_tenant_id() and current_worker_role() in ('executive', 'hc_admin'));
