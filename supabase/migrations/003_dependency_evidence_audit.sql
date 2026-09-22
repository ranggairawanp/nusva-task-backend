create table dependencies (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  from_work_item_id uuid not null references work_items(id),
  to_work_item_id uuid not null references work_items(id),
  kind text not null check (kind in ('BLOCKS','DEPENDS_ON')),
  created_at timestamptz not null default now(),
  unique (from_work_item_id, to_work_item_id, kind)
);

create table blockers (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  work_item_id uuid not null references work_items(id),
  reason text not null,
  raised_by uuid not null references workers(id),
  status text not null default 'OPEN' check (status in ('OPEN','RESOLVED')),
  resolved_at timestamptz
);

create table evidence (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  work_item_id uuid references work_items(id),
  commitment_id uuid references commitments(id),
  type text not null check (type in
    ('SYSTEM_EVENT','CHECKLIST','ATTACHMENT','LINK','NOTE','METRIC','APPROVAL')),
  payload jsonb not null,
  created_by uuid not null references workers(id),
  created_at timestamptz not null default now()
);

create table audit_log (
  id bigint generated always as identity primary key,
  tenant_id uuid not null,
  actor_id uuid not null,
  action text not null,
  object_type text not null,
  object_id uuid not null,
  before jsonb,
  after jsonb,
  created_at timestamptz not null default now()
);

create index idx_dependencies_from on dependencies(from_work_item_id);
create index idx_dependencies_to on dependencies(to_work_item_id);
create index idx_blockers_work_item on blockers(work_item_id);
create index idx_blockers_status on blockers(status);
create index idx_evidence_work_item on evidence(work_item_id);
create index idx_evidence_commitment on evidence(commitment_id);
create index idx_audit_log_tenant on audit_log(tenant_id);
create index idx_audit_log_object on audit_log(object_type, object_id);
