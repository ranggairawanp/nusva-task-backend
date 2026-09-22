create table tenants (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table organizations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  name text not null
);

create table legal_entities (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  organization_id uuid not null references organizations(id),
  code text not null,
  name text not null,
  unique (tenant_id, code)
);

create table business_units (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  legal_entity_id uuid not null references legal_entities(id),
  name text not null
);

create table teams (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  business_unit_id uuid not null references business_units(id),
  name text not null
);

create table positions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  team_id uuid not null references teams(id),
  title text not null
);

create table workers (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  position_id uuid references positions(id),
  team_id uuid references teams(id),
  auth_user_id uuid not null references auth.users(id),
  full_name text not null,
  role text not null check (role in ('employee','manager','executive','hc_admin')),
  unique (tenant_id, auth_user_id)
);

create index idx_legal_entities_tenant on legal_entities(tenant_id);
create index idx_business_units_tenant on business_units(tenant_id);
create index idx_business_units_entity on business_units(legal_entity_id);
create index idx_teams_tenant on teams(tenant_id);
create index idx_teams_bu on teams(business_unit_id);
create index idx_workers_tenant on workers(tenant_id);
create index idx_workers_team on workers(team_id);
create index idx_workers_auth_user on workers(auth_user_id);
