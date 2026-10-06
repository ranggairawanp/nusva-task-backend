-- 030: halaman "Apa yang dilihat HC", Tahap 1b bagian pertama. Tayang lebih dulu dari Talenta
-- dan Adopsi live, supaya karyawan tahu apa yang dilihat HC sebelum angka barunya dipakai.
--
-- 1. RPC hc_transparency() untuk SEMUA pekerja yang login di tenant (bukan hanya HC). Isinya:
--    - ambang kelompok tenant (tenants.hc_min_group);
--    - berapa kali dashboard HC dibuka dalam 30 hari terakhir, berapa orang yang membuka per
--      peran (eksekutif, HC), dan tanggal terakhir dibuka. Dihitung dari audit_log (READ pada
--      hc_overview dan hc_people), tanpa nama dan tanpa isi hasilnya;
--    - jumlah karyawan di siklus penilaian yang sedang berjalan, dan apakah pemanggil termasuk.
--    audit_log tetap hanya terbaca HC (migration 027); fungsi ini hanya mengeluarkan hitungan.
-- 2. Fungsi STABLE, security definer, tenant dari akun pemanggil. Tidak menulis apa pun.
-- 3. Tidak ada DROP, REVOKE ALL, atau DELETE.

create or replace function hc_transparency()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_tenant uuid := current_tenant_id();
  v_actor uuid := current_worker_id();
  v_cycle uuid;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;

  select id into v_cycle from review_cycles
   where tenant_id = v_tenant and status = 'OPEN'
   order by starts_on desc, created_at desc limit 1;

  return jsonb_build_object(
    'as_of', now(),
    'today', (now() at time zone 'Asia/Jakarta')::date,
    'min_group', (select hc_min_group from tenants where id = v_tenant),
    'reads_30d', (select count(*) from audit_log
                   where tenant_id = v_tenant and action = 'READ'
                     and object_type in ('hc_overview', 'hc_people')
                     and created_at > now() - interval '30 days'),
    'readers_30d', (select jsonb_build_object(
                      'executive', count(distinct a.actor_id) filter (where w.role = 'executive'),
                      'hc', count(distinct a.actor_id) filter (where w.role = 'hc_admin'))
                      from audit_log a join workers w on w.id = a.actor_id
                     where a.tenant_id = v_tenant and a.action = 'READ'
                       and a.object_type in ('hc_overview', 'hc_people')
                       and a.created_at > now() - interval '30 days'),
    'last_read', (select max(created_at) from audit_log
                   where tenant_id = v_tenant and action = 'READ'
                     and object_type in ('hc_overview', 'hc_people')),
    'cycle_people', case when v_cycle is null then null else
                      (select count(*) from performance_reviews pr join workers w on w.id = pr.employee_id
                        where pr.cycle_id = v_cycle and w.role = 'employee') end,
    'me_in_cycle', case when v_cycle is null then null else
                     exists (select 1 from performance_reviews where cycle_id = v_cycle and employee_id = v_actor) end
  );
end;
$$;

revoke execute on function hc_transparency() from public, anon;
grant execute on function hc_transparency() to authenticated;
