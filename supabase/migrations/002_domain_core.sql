create table business_outcomes (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  baseline numeric,
  target numeric,
  current_value numeric,
  period text,
  unit text
);

create table priorities (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  team_id uuid not null references teams(id),
  business_outcome_id uuid references business_outcomes(id),
  scope text not null check (scope in ('ORGANIZATION','ENTITY','UNIT','TEAM','INDIVIDUAL')),
  status text not null default 'NOT_STARTED' check (status in ('NOT_STARTED','ON_TRACK','WATCH','AT_RISK','ACHIEVED','CLOSED','CANCELLED')),
  statement text not null,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table drivers (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  priority_id uuid not null references priorities(id),
  title text not null,
  hypothesis text,
  target numeric,
  actual numeric not null default 0,
  unit text,
  version integer not null default 1
);

create table commitments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  owner_id uuid not null references workers(id),
  priority_id uuid references priorities(id),
  period text not null,
  target numeric,
  current_value numeric,
  confidence text,
  status text not null default 'ON_TRACK',
  version integer not null default 1
);

create table commitment_checkins (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  commitment_id uuid not null references commitments(id),
  note text,
  confidence text,
  created_at timestamptz not null default now()
);

create table initiatives (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  owner_id uuid not null references workers(id),
  sponsor_id uuid references workers(id),
  scope text,
  name text not null,
  start_at date,
  end_at date,
  status text not null default 'ON_TRACK',
  progress_pct numeric not null default 0,
  version integer not null default 1
);

create table initiative_milestones (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  initiative_id uuid not null references initiatives(id),
  title text not null,
  due_at date,
  done boolean not null default false
);

create table recurring_templates (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  team_id uuid not null references teams(id),
  title text not null,
  rrule text not null,
  default_fields jsonb not null default '{}'::jsonb
);

create table work_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  team_id uuid not null references teams(id),
  type text not null check (type in ('TASK','ACTION','MILESTONE','RECURRING_WORK')),
  title text not null,
  description text,
  creator_id uuid not null references workers(id),
  owner_id uuid not null references workers(id),
  contributors uuid[] not null default '{}',
  status text not null default 'PLANNED' check (status in ('PLANNED','READY','IN_PROGRESS','WAITING','BLOCKED','DONE','CANCELLED')),
  priority_level text not null default 'NORMAL' check (priority_level in ('LOW','NORMAL','HIGH','URGENT')),
  start_at timestamptz,
  due_at timestamptz,
  completed_at timestamptz,
  estimated_effort numeric,
  actual_effort numeric,
  priority_id uuid references priorities(id),
  driver_id uuid references drivers(id),
  initiative_id uuid references initiatives(id),
  commitment_id uuid references commitments(id),
  parent_work_id uuid references work_items(id),
  template_id uuid references recurring_templates(id),
  qty numeric,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table checklist_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  work_item_id uuid not null references work_items(id),
  title text not null,
  done boolean not null default false,
  position integer not null default 0
);

create index idx_priorities_tenant on priorities(tenant_id);
create index idx_priorities_team on priorities(team_id);
create index idx_drivers_priority on drivers(priority_id);
create index idx_commitments_owner on commitments(owner_id);
create index idx_initiatives_tenant on initiatives(tenant_id);
create index idx_work_items_tenant on work_items(tenant_id);
create index idx_work_items_team on work_items(team_id);
create index idx_work_items_owner on work_items(owner_id);
create index idx_work_items_status on work_items(status);
create index idx_work_items_parent on work_items(parent_work_id);
create index idx_checklist_items_work_item on checklist_items(work_item_id);
