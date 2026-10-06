-- 035: salinan data potensi untuk permintaan karyawan (SOP Permintaan Salinan Data Potensi).
-- Sejak 034 potensi tidak terbaca karyawan; hak aksesnya dipenuhi lewat permintaan tertulis ke HC
-- (UU 27/2022). Sampai sekarang HC tidak punya jalur sendiri: data ditarik admin sistem lewat
-- review_potentials dan tidak tercatat otomatis.
--
-- 1. RPC potential_copy(p_employee_id, p_request_no): data potensi satu karyawan di SEMUA siklus
--    yang masih disimpan, untuk dibuat salinan. Aturan:
--    - hanya hc_admin (HC pusat pemegang SOP), bukan eksekutif atau manajer;
--    - nomor permintaan wajib, format SPD-tahun-urutan (SPD-2026-001), supaya setiap penarikan
--      terikat ke satu baris register;
--    - tidak untuk data diri sendiri (permintaan HC tentang dirinya diproses petugas lain);
--    - setiap panggilan dicatat di audit_log: READ, object_type potential_copy, object_id = karyawan,
--      after = {request_no}. audit_log tetap hanya terbaca HC (027).
--    Keluaran: nama, posisi, tim, lalu per siklus: nama siklus, status siklus, potensi, alasan,
--    pengisi, tanggal, dan rating terkalibrasi (untuk posisi 9-box). Tanpa data orang lain selain
--    nama pengisi, yang termasuk rekam jejak pemrosesan.
-- 2. hc_transparency() (030) diganti dengan isi yang sama ditambah my_copies dan my_copy_last:
--    berapa kali salinan potensi pemanggil ditarik HC dan kapan terakhir, supaya karyawan bisa
--    melihatnya di halaman "Apa yang dilihat HC".
-- 3. Tidak ada DROP, REVOKE ALL, atau DELETE.

create or replace function potential_copy(p_employee_id uuid, p_request_no text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_tenant uuid := current_tenant_id();
  v_actor uuid := current_worker_id();
  v_no text := upper(btrim(coalesce(p_request_no, '')));
  v_emp workers;
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  if current_worker_role() <> 'hc_admin' then
    raise exception 'not authorized to pull a potential copy';
  end if;
  if v_no !~ '^SPD-[0-9]{4}-[0-9]{3,}$' then
    raise exception 'invalid request number';
  end if;
  select * into v_emp from workers where id = p_employee_id and tenant_id = v_tenant;
  if v_emp.id is null then
    raise exception 'employee not found';
  end if;
  if v_emp.id = v_actor then
    raise exception 'not authorized to pull your own copy';
  end if;

  insert into audit_log (tenant_id, actor_id, action, object_type, object_id, after)
  values (v_tenant, v_actor, 'READ', 'potential_copy', v_emp.id, jsonb_build_object('request_no', v_no));

  select jsonb_build_object(
    'as_of', now(),
    'request_no', v_no,
    'pulled_by', (select full_name from workers where id = v_actor),
    'employee', jsonb_build_object(
      'name', v_emp.full_name,
      'position', (select title from positions where id = v_emp.position_id),
      'team', (select name from teams where id = v_emp.team_id)),
    'cycles', coalesce((
      select jsonb_agg(jsonb_build_object(
               'cycle', c.name, 'status', c.status, 'starts_on', c.starts_on,
               'potential', pr.potential, 'note', pr.potential_note,
               'set_at', pr.potential_at, 'set_by', w.full_name,
               'calib_rating', pr.calib_rating)
             order by c.starts_on desc)
        from performance_reviews pr
        join review_cycles c on c.id = pr.cycle_id
        left join workers w on w.id = pr.potential_by
       where pr.tenant_id = v_tenant and pr.employee_id = v_emp.id), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

revoke execute on function potential_copy(uuid, text) from public, anon;
grant execute on function potential_copy(uuid, text) to authenticated;

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
                     exists (select 1 from performance_reviews where cycle_id = v_cycle and employee_id = v_actor) end,
    'my_copies', (select count(*) from audit_log
                   where tenant_id = v_tenant and action = 'READ'
                     and object_type = 'potential_copy' and object_id = v_actor),
    'my_copy_last', (select max(created_at) from audit_log
                      where tenant_id = v_tenant and action = 'READ'
                        and object_type = 'potential_copy' and object_id = v_actor)
  );
end;
$$;

revoke execute on function hc_transparency() from public, anon;
grant execute on function hc_transparency() to authenticated;
