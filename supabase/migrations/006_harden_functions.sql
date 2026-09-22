-- Pin search_path on trigger functions so they can't be hijacked via a mutable search_path
alter function validate_work_item_transition() set search_path = public;
alter function reject_circular_dependency() set search_path = public;
alter function enforce_priority_cap() set search_path = public;
alter function enforce_driver_cap() set search_path = public;

-- These helper functions only ever return facts about the CALLING user's own row
-- (looked up via auth.uid()), never another tenant's data, so SECURITY DEFINER is
-- intentional and safe for signed-in users. Unauthenticated (anon) callers get no
-- useful data back (auth.uid() is null for them), but revoke EXECUTE anyway so the
-- linter's anon-RPC warning is closed rather than just benign.
revoke execute on function current_tenant_id() from anon;
revoke execute on function current_worker_id() from anon;
revoke execute on function current_worker_role() from anon;
