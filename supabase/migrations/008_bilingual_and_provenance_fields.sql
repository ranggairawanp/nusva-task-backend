-- All affected tables are still empty (0 rows), so drop+recreate as jsonb is safe here
-- and needs no backfill. Do not reuse this drop+add pattern once real rows exist.

alter table priorities drop column statement;
alter table priorities add column statement jsonb not null;

alter table drivers drop column title;
alter table drivers add column title jsonb not null;
alter table drivers drop column hypothesis;
alter table drivers add column hypothesis jsonb;
alter table drivers drop column unit;
alter table drivers add column unit jsonb;

alter table work_items drop column title;
alter table work_items add column title jsonb not null;

alter table checklist_items drop column title;
alter table checklist_items add column title jsonb not null;

alter table business_units drop column name;
alter table business_units add column name jsonb not null;

-- Every number states its origin (CLAUDE.md): who reported a Business Outcome value, and when.
alter table business_outcomes add column label jsonb;
alter table business_outcomes add column reported_by uuid references workers(id);
alter table business_outcomes add column reported_at timestamptz;
