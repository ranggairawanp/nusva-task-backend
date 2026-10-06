-- 031: Talenta dan Adopsi live, Tahap 1b bagian 2. Melanjutkan pola hc_overview() (027):
-- hanya angka agregat, ambang kelompok tenants.hc_min_group, penahanan kelompok kecil lewat
-- hc_suppress(), dan setiap panggilan tercatat di audit_log.
--
-- 1. Talenta dari rating TERKALIBRASI saja (calib_rating), bukan review manajer yang belum
--    dikalibrasi. Sumbu kinerja tiga pita: Belum Memenuhi (0), Memenuhi (1), Melampaui atau Luar
--    Biasa (2 dan 3). Sumbu potensi dari performance_reviews.potential (0 sampai 2). Kotak 9-box
--    hanya dikirim kalau jumlah orang terkalibrasi yang punya potensi minimal ambang; per area lewat
--    hc_suppress(). Hitungan proses (di siklus, sudah direview, sudah dikalibrasi) ikut dikirim
--    supaya layar bisa menulis berapa yang belum masuk.
-- 2. Adopsi dari tindakan nyata di aplikasi, bukan baris tugas otomatis. Sumbernya audit_log, yang
--    hanya terisi dari sesi login (log_audit_event, migration 010): seed migration dan cron
--    penyegar data demo tidak tercatat. Yang dikecualikan karena dibuat sistem, bukan diketik orang:
--    INSERT checklist_items, dan INSERT work_items untuk instance tugas rutin (template_id) atau
--    tindak lanjut audit (parent_work_id). READ (pembukaan dashboard) juga tidak dihitung.
--    Populasi: karyawan dan manajer yang bisa login (auth_user_id ada, bukan is_demo). Aktif = minimal
--    satu tindakan pada minggu itu (Senin sampai Minggu, WIB). Delapan minggu terakhir; minggu
--    sebelum tindakan tercatat pertama dikirim null, bukan nol.
-- 3. Supaya komentar, Weekly Check-in, handover, dan penilaian ikut terhitung, trigger audit migration
--    010 dipasang juga di work_item_comments, priority_checkins, dan performance_reviews
--    (shift_handovers sudah punya trigger yang sama sejak 016). audit_log tetap hanya terbaca HC.
-- 4. Data yang belum ada di sistem (risiko resign, turnover, kontrak, survei merasa diawasi,
--    saran Nexa diterima) tidak dikirim. Layar menulis "Belum ada" beserta data yang dibutuhkan.
-- 5. Tidak ada DROP, REVOKE ALL, atau DELETE.

create trigger trg_audit_work_item_comments after insert or update or delete on work_item_comments
  for each row execute function log_audit_event();
create trigger trg_audit_priority_checkins after insert or update or delete on priority_checkins
  for each row execute function log_audit_event();
create trigger trg_audit_performance_reviews after insert or update or delete on performance_reviews
  for each row execute function log_audit_event();

create or replace function hc_people()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_tenant uuid := current_tenant_id();
  v_actor uuid := current_worker_id();
  v_k integer;
  v_week date := (date_trunc('week', now() at time zone 'Asia/Jakarta'))::date;
  v_cycle uuid;
  v_since timestamptz;
  v_result jsonb;
begin
  if current_worker_role() not in ('executive','hc_admin') then
    raise exception 'not authorized to view the HC overview';
  end if;

  select hc_min_group into v_k from tenants where id = v_tenant;
  select id into v_cycle from review_cycles
   where tenant_id = v_tenant and status = 'OPEN'
   order by starts_on desc, created_at desc limit 1;

  insert into audit_log (tenant_id, actor_id, action, object_type, object_id, after)
  values (v_tenant, v_actor, 'READ', 'hc_people', v_tenant, '{}'::jsonb);

  -- tindakan manusia yang dihitung untuk adopsi
  select min(a.created_at) into v_since
    from audit_log a
   where a.tenant_id = v_tenant and a.action <> 'READ'
     and not (a.object_type = 'checklist_items' and a.action = 'INSERT')
     and not (a.object_type = 'work_items' and a.action = 'INSERT'
              and (a.after->>'template_id' is not null or a.after->>'parent_work_id' is not null));

  with tal as (
    select upper(le.code) as area, pr.mgr_rating, pr.calib_rating, pr.potential
      from performance_reviews pr
      join workers w on w.id = pr.employee_id
      join teams t on t.id = w.team_id
      join business_units bu on bu.id = t.business_unit_id
      join legal_entities le on le.id = bu.legal_entity_id
     where v_cycle is not null and pr.cycle_id = v_cycle and w.role = 'employee'
  ),
  boxed as (
    select area, potential as pot,
           case when calib_rating = 0 then 0 when calib_rating = 1 then 1 else 2 end as perf
      from tal where calib_rating is not null and potential is not null
  ),
  grid_area as (
    select area, count(*) as n,
           jsonb_build_array(
             jsonb_build_array(count(*) filter (where pot = 0 and perf = 0), count(*) filter (where pot = 0 and perf = 1), count(*) filter (where pot = 0 and perf = 2)),
             jsonb_build_array(count(*) filter (where pot = 1 and perf = 0), count(*) filter (where pot = 1 and perf = 1), count(*) filter (where pot = 1 and perf = 2)),
             jsonb_build_array(count(*) filter (where pot = 2 and perf = 0), count(*) filter (where pot = 2 and perf = 1), count(*) filter (where pot = 2 and perf = 2))) as grid
      from boxed group by area
  ),
  pop as (
    select w.id, upper(le.code) as area
      from workers w
      join teams t on t.id = w.team_id
      join business_units bu on bu.id = t.business_unit_id
      join legal_entities le on le.id = bu.legal_entity_id
     where w.tenant_id = v_tenant and w.role in ('employee','manager')
       and w.auth_user_id is not null and not w.is_demo
  ),
  acts as (
    select distinct a.actor_id, (date_trunc('week', a.created_at at time zone 'Asia/Jakarta'))::date as wk
      from audit_log a
     where a.tenant_id = v_tenant and a.action <> 'READ'
       and a.created_at >= (v_week - 49)::timestamp at time zone 'Asia/Jakarta'
       and a.actor_id in (select id from pop)
       and not (a.object_type = 'checklist_items' and a.action = 'INSERT')
       and not (a.object_type = 'work_items' and a.action = 'INSERT'
                and (a.after->>'template_id' is not null or a.after->>'parent_work_id' is not null))
  ),
  weeks as (select (v_week - 7 * g)::date as wk from generate_series(7, 0, -1) g),
  pop_area as (
    select area, count(*) as n,
           (select count(distinct ac.actor_id) from acts ac join pop p2 on p2.id = ac.actor_id
             where p2.area = pop.area and ac.wk = v_week - 7) as active_last,
           (select count(distinct ac.actor_id) from acts ac join pop p2 on p2.id = ac.actor_id
             where p2.area = pop.area and ac.wk >= v_week - 28 and ac.wk < v_week) as active_4w
      from pop group by area
  )
  select jsonb_build_object(
    'as_of', now(), 'today', (now() at time zone 'Asia/Jakarta')::date, 'week_start', v_week,
    'min_group', v_k,
    'demo', exists (select 1 from workers where tenant_id = v_tenant and is_demo),
    'talent', jsonb_build_object(
      'in_cycle', (select count(*) from tal),
      'reviewed', (select count(*) from tal where mgr_rating is not null),
      'calibrated', (select count(*) from tal where calib_rating is not null),
      'with_potential', (select count(*) from tal where potential is not null),
      'n', (select count(*) from boxed),
      'grid', case when (select count(*) from boxed) >= v_k then
                jsonb_build_array(
                  jsonb_build_array((select count(*) from boxed where pot = 0 and perf = 0), (select count(*) from boxed where pot = 0 and perf = 1), (select count(*) from boxed where pot = 0 and perf = 2)),
                  jsonb_build_array((select count(*) from boxed where pot = 1 and perf = 0), (select count(*) from boxed where pot = 1 and perf = 1), (select count(*) from boxed where pot = 1 and perf = 2)),
                  jsonb_build_array((select count(*) from boxed where pot = 2 and perf = 0), (select count(*) from boxed where pot = 2 and perf = 1), (select count(*) from boxed where pot = 2 and perf = 2))) end,
      'by_area', hc_suppress((select coalesce(jsonb_agg(jsonb_build_object('group', area, 'area', area, 'n', n, 'grid', grid) order by area), '[]'::jsonb) from grid_area), v_k)),
    'adoption', jsonb_build_object(
      'n', (select count(*) from pop),
      'since', v_since,
      'weeks', case when (select count(*) from pop) >= v_k then
                 (select jsonb_agg(jsonb_build_object('week', wk,
                     'active', case when v_since is null or wk + 7 <= (v_since at time zone 'Asia/Jakarta')::date then null
                                    else (select count(distinct actor_id) from acts where acts.wk = weeks.wk) end) order by wk) from weeks) end,
      'by_area', hc_suppress((select coalesce(jsonb_agg(jsonb_build_object('group', area, 'area', area, 'n', n,
                     'active_last', active_last, 'active_4w', active_4w) order by area), '[]'::jsonb) from pop_area), v_k))
  ) into v_result;

  return v_result;
end;
$$;

revoke execute on function hc_people() from public, anon;
grant execute on function hc_people() to authenticated;
