-- Prior revoke only stripped the direct anon grant; PostgREST also exposes functions
-- via the implicit PUBLIC grant that CREATE FUNCTION adds by default. Strip that too.
revoke execute on function current_tenant_id() from public;
revoke execute on function current_worker_id() from public;
revoke execute on function current_worker_role() from public;

-- Re-grant to authenticated only: this is the intentional, safe caller (see prior migration's comment).
grant execute on function current_tenant_id() to authenticated;
grant execute on function current_worker_id() to authenticated;
grant execute on function current_worker_role() to authenticated;
