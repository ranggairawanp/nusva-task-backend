-- Migration 010's `revoke execute ... from public` did not cover it: Supabase
-- grants EXECUTE on newly created functions to `anon` via a default privilege
-- separate from the PUBLIC pseudo-role grant, so complete_work_item,
-- raise_blocker and resolve_blocker were callable by anonymous, signed-out
-- callers. In practice an anon call fails anyway (current_tenant_id() is
-- null with no auth.uid(), so the ownership lookup returns "not found"), but
-- there is no reason to leave that surface open -- same hardening this
-- codebase already applied to the current_*() helpers in migrations 006/007.
revoke execute on function complete_work_item(uuid) from anon;
revoke execute on function raise_blocker(uuid, text) from anon;
revoke execute on function resolve_blocker(uuid) from anon;
