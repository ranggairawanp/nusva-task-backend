-- Migration 009 seeded due_at relative to data.js's fictional TODAY_ISO
-- (2026-09-12), since that is the date the source prototype's demo data was
-- written against. Now that the nusvapeople-task frontend is being connected
-- to this backend for real, "today"/"tomorrow"/"overdue" need to be computed
-- against the real current date, or every seeded item would show as overdue
-- the moment more than a day passes. This is a one-time re-anchor of the
-- Phase 1 demo seed to real wall-clock dates so the live connection is
-- demonstrable; it is not something a real system would ever need to do
-- again; due dates set from here on come from real user input.
--
-- Same day-of-week relationships as the original seed: three items due
-- "today", three due "tomorrow", one due two days ago ("overdue"), all at
-- 17:00 WIB. The two already-DONE items (task 5, task 8) are re-anchored
-- too, for consistency, though their due date no longer affects anything.
update work_items set due_at = '2026-09-23 17:00:00+07'
  where id in (
    'a0000000-0000-0000-0000-000000000001',
    'a0000000-0000-0000-0000-000000000002',
    'a0000000-0000-0000-0000-000000000003',
    'a0000000-0000-0000-0000-000000000005',
    'a0000000-0000-0000-0000-000000000007',
    'a0000000-0000-0000-0000-000000000008'
  );
update work_items set due_at = '2026-09-24 17:00:00+07'
  where id in (
    'a0000000-0000-0000-0000-000000000004',
    'a0000000-0000-0000-0000-000000000006',
    'a0000000-0000-0000-0000-000000000010'
  );
update work_items set due_at = '2026-09-21 17:00:00+07'
  where id = 'a0000000-0000-0000-0000-000000000009';
