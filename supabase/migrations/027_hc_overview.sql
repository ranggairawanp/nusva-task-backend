-- Dashboard HC dengan data live, Tahap 1a: kesiapan kalibrasi, Fairness, ritme Weekly Check-in,
-- dan praktik orang berdampingan dengan hasil per outlet. Disetujui pemilik produk (rancangan
-- versi 3, keputusan K1 sampai K6, 6 Oktober 2026).
--
-- Keputusan desain:
-- 1. RPC hc_overview(p_level) untuk executive dan hc_admin, pola yang sama dengan
--    executive_overview(): tenant dari akun pemanggil, agregasi di server. Keluarannya hanya
--    angka agregat. Tidak ada nama, id karyawan, atau baris per orang.
-- 2. Ambang kelompok tenants.hc_min_group (bawaan 10, minimal 5). Angka per orang (rating,
--    bukti, kalibrasi) untuk kelompok di bawah ambang tidak dikirim: diganti
--    {suppressed:true, reason:'small'} tanpa jumlah orang. Penahanan kedua: kalau tepat satu
--    kelompok tertahan, kelompok terkecil berikutnya ikut ditahan (reason:'secondary'), supaya
--    angka kelompok kecil tidak bisa dihitung dari total dikurangi kelompok lain.
-- 3. Pengelompokan bawaan per area (kode badan hukum, misalnya OTU dan OTS). Tingkat outlet
--    (p_level = 'outlet') hanya membuka outlet di area yang semua outletnya lolos ambang;
--    outlet di area lain ditahan dengan reason:'area'.
-- 4. Angka tingkat tim (ritme Weekly Check-in, prioritas bertarget, progres angka hasil) tidak
--    ditahan: itu catatan kerja tim dan manajernya, dan sudah tampil per outlet di
--    executive_overview().
-- 5. Bukti penilaian: tugas selesai milik karyawan dalam periode siklus yang menunjuk Action
--    Plan atau merupakan tugas rutin (kepatuhan SOP). Keterbatasan yang diterima: tugas rutin
--    dihitung atas nama pemilik tugasnya, karena checklist_items tidak mencatat siapa yang
--    mencentang.
-- 6. Selisih antarpenilai memakai rata-rata rating review manajer per penilai, hanya penilai
--    dengan minimal 5 penilaian, dan null kalau kurang dari dua penilai memenuhi syarat.
-- 7. Setiap panggilan dicatat di audit_log (action READ, object_type hc_overview), tanpa
--    menyimpan isi hasilnya. Karena itu fungsi ini VOLATILE, bukan baca saja murni.
-- 8. audit_log sebelumnya terbaca seluruh pekerja di tenant, padahal isinya jejak aktivitas
--    per orang. Policy SELECT dipersempit ke hc_admin, sesuai aturan privasi rancangan
--    (aktivitas per orang tidak ditampilkan ke siapa pun di aplikasi). Aplikasi tidak membaca
--    audit_log, jadi tidak ada layar yang berubah.
-- 9. workers.is_demo menandai karyawan data demo (migration 028) supaya bisa diberi label dan
--    dibersihkan. Kolom ini hanya bisa diubah dari migration, tidak dari aplikasi.
-- 10. Tidak ada DROP, REVOKE ALL, atau DELETE.

alter table tenants add column hc_min_group integer not null default 10
  check (hc_min_group between 5 and 100);

alter table workers add column is_demo boolean not null default false;

create or replace function guard_worker_is_demo()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_worker_id() is null then
    return new;
  end if;
  if (tg_op = 'INSERT' and new.is_demo)
     or (tg_op = 'UPDATE' and new.is_demo is distinct from old.is_demo) then
    raise exception 'is_demo can only be set by migrations';
  end if;
  return new;
end;
$$;

create trigger trg_guard_worker_is_demo
  before insert or update on workers
  for each row execute function guard_worker_is_demo();

alter policy audit_log_select on audit_log
  using (tenant_id = current_tenant_id() and current_worker_role() = 'hc_admin');

-- Penahanan kelompok kecil. p_groups: [{group, n, ...angka}]. Mengembalikan array yang sama
-- dengan angka kelompok tertahan diganti {group, suppressed:true, reason}.
create or replace function hc_suppress(p_groups jsonb, p_k integer)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_small integer;
  v_second text;
  v_out jsonb := '[]'::jsonb;
  r jsonb;
begin
  if p_groups is null or jsonb_array_length(p_groups) = 0 then
    return '[]'::jsonb;
  end if;
  select count(*) into v_small
    from jsonb_array_elements(p_groups) e
   where coalesce((e->>'n')::integer, 0) < p_k and not coalesce((e->>'suppressed')::boolean, false);
  if v_small = 1 then
    select e->>'group' into v_second
      from jsonb_array_elements(p_groups) e
     where coalesce((e->>'n')::integer, 0) >= p_k and not coalesce((e->>'suppressed')::boolean, false)
     order by (e->>'n')::integer, e->>'group'
     limit 1;
  end if;
  for r in select e from jsonb_array_elements(p_groups) e loop
    if coalesce((r->>'suppressed')::boolean, false) then
      v_out := v_out || jsonb_build_array(jsonb_build_object('group', r->'group', 'area', r->'area',
                                                             'suppressed', true, 'reason', r->'reason'));
    elsif coalesce((r->>'n')::integer, 0) < p_k then
      v_out := v_out || jsonb_build_array(jsonb_build_object('group', r->'group', 'area', r->'area',
                                                             'suppressed', true, 'reason', 'small'));
    elsif r->>'group' = v_second then
      v_out := v_out || jsonb_build_array(jsonb_build_object('group', r->'group', 'area', r->'area',
                                                             'suppressed', true, 'reason', 'secondary'));
    else
      v_out := v_out || jsonb_build_array(r);
    end if;
  end loop;
  return v_out;
end;
$$;

create or replace function hc_overview(p_level text default 'area')
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
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_week date := (date_trunc('week', now() at time zone 'Asia/Jakarta'))::date;
  v_cycle review_cycles%rowtype;
  v_people jsonb := '[]'::jsonb;
  v_result jsonb;
begin
  if current_worker_role() not in ('executive','hc_admin') then
    raise exception 'not authorized to view the HC overview';
  end if;
  if p_level not in ('area','outlet') then
    raise exception 'invalid level';
  end if;

  select hc_min_group into v_k from tenants where id = v_tenant;
  select * into v_cycle from review_cycles
   where tenant_id = v_tenant and status = 'OPEN'
   order by starts_on desc, created_at desc limit 1;

  insert into audit_log (tenant_id, actor_id, action, object_type, object_id, after)
  values (v_tenant, v_actor, 'READ', 'hc_overview', v_tenant, jsonb_build_object('level', p_level));

  -- Satu baris per karyawan di siklus terbuka, hanya dipakai di dalam fungsi ini.
  if v_cycle.id is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'team', t.name, 'area', upper(le.code),
             'rated', pr.mgr_rating is not null,
             'final', coalesce(pr.calib_rating, pr.mgr_rating),
             'calibrated', pr.calib_rating is not null,
             'changed', pr.calib_rating is not null and pr.calib_rating <> pr.mgr_rating,
             'mgr_by', pr.mgr_by, 'mgr_rating', pr.mgr_rating,
             'evidence', (select count(*) from work_items wi
                           where wi.owner_id = w.id and wi.status = 'DONE'
                             and (wi.driver_id is not null or wi.template_id is not null)
                             and (wi.completed_at at time zone 'Asia/Jakarta')::date
                                 between v_cycle.starts_on and least(v_cycle.ends_on, v_today)))), '[]'::jsonb)
      into v_people
      from performance_reviews pr
      join workers w on w.id = pr.employee_id
      join teams t on t.id = w.team_id
      join business_units bu on bu.id = t.business_unit_id
      join legal_entities le on le.id = bu.legal_entity_id
     where pr.cycle_id = v_cycle.id and w.role = 'employee';
  end if;

  with people as (
    select p->>'team' as team, p->>'area' as area,
           (p->>'rated')::boolean as rated, (p->>'final')::integer as final,
           (p->>'calibrated')::boolean as calibrated, (p->>'changed')::boolean as changed,
           (p->>'mgr_by')::uuid as mgr_by, (p->>'mgr_rating')::integer as mgr_rating,
           (p->>'evidence')::integer as evidence
      from jsonb_array_elements(v_people) p
  ),
  rated as (select * from people where rated),
  grp as (
    select case when p_level = 'outlet' then team else area end as g, min(area) as area,
           count(*) as n,
           jsonb_build_array(count(*) filter (where final = 0), count(*) filter (where final = 1),
                             count(*) filter (where final = 2), count(*) filter (where final = 3)) as dist,
           count(*) filter (where evidence >= 3) as with_evidence
      from rated group by 1
  ),
  outlet_ok as (
    select area, bool_and(n >= v_k) as ok
      from (select team, min(area) as area, count(*) as n from rated group by team) o group by area
  ),
  grp_json as (
    select coalesce(jsonb_agg(
             case when p_level = 'outlet' and not coalesce((select ok from outlet_ok where outlet_ok.area = grp.area), false)
                  then jsonb_build_object('group', g, 'area', grp.area, 'suppressed', true, 'reason', 'area')
                  else jsonb_build_object('group', g, 'area', grp.area, 'n', n, 'dist', dist, 'with_evidence', with_evidence)
             end order by grp.area, g), '[]'::jsonb) as j
      from grp
  ),
  raters as (
    select mgr_by, avg(mgr_rating)::numeric as avg_rating from rated
     where mgr_by is not null group by mgr_by having count(*) >= 5
  ),
  pri as (
    select p.id, p.team_id, t.name as team, upper(le.code) as area,
           bo.baseline, bo.target, bo.current_value
      from priorities p
      join teams t on t.id = p.team_id
      join business_units bu on bu.id = t.business_unit_id
      join legal_entities le on le.id = bu.legal_entity_id
      left join business_outcomes bo on bo.id = p.business_outcome_id
     where p.tenant_id = v_tenant and p.status not in ('CLOSED','CANCELLED')
  ),
  ck as (
    select pc.priority_id, pc.week_start,
           (pc.created_at at time zone 'Asia/Jakarta')::date < pc.week_start + 7 as on_time
      from priority_checkins pc
     where pc.priority_id in (select id from pri)
       and pc.week_start between v_week - 28 and v_week - 7
  ),
  pri_stat as (
    select pri.*, (select count(distinct week_start) from ck where ck.priority_id = pri.id) as weeks,
           case when target is not null and baseline is not null and target <> baseline and current_value is not null
                then greatest(0, least(100, round((current_value - baseline) / (target - baseline) * 100)))
           end as progress
      from pri
  ),
  outlets as (
    select t.name as team, upper(le.code) as area,
           (select count(*) from pri_stat s where s.team_id = t.id) as priorities,
           (select count(*) from pri_stat s where s.team_id = t.id and s.weeks = 4) as running,
           (select count(*) from ck join pri on pri.id = ck.priority_id where pri.team_id = t.id) as checkins,
           (select round(avg(progress)) from pri_stat s where s.team_id = t.id) as progress,
           exists (select 1 from pri_stat s where s.team_id = t.id and s.target is not null) as has_target
      from teams t
      join business_units bu on bu.id = t.business_unit_id
      join legal_entities le on le.id = bu.legal_entity_id
     where t.tenant_id = v_tenant
  )
  select jsonb_build_object(
    'as_of', now(), 'today', v_today, 'week_start', v_week, 'level', p_level,
    'min_group', v_k,
    'employees', (select count(*) from workers where tenant_id = v_tenant and role = 'employee'),
    'demo', exists (select 1 from workers where tenant_id = v_tenant and is_demo),
    'cycle', case when v_cycle.id is null then null else jsonb_build_object(
               'name', v_cycle.name, 'starts_on', v_cycle.starts_on, 'ends_on', v_cycle.ends_on,
               'due_self', v_cycle.due_self, 'due_mgr', v_cycle.due_mgr, 'due_calib', v_cycle.due_calib) end,
    'calib', jsonb_build_object(
               'total', (select count(*) from people),
               'reviews_in', (select count(*) from rated),
               'calibrated', (select count(*) from rated where calibrated),
               'without_evidence', case when (select count(*) from rated) >= v_k
                                        then (select count(*) from rated where evidence < 3) end),
    'reviews', jsonb_build_object(
               'rated', (select count(*) from rated),
               'dist', case when (select count(*) from rated) >= v_k
                            then jsonb_build_array((select count(*) from rated where final = 0), (select count(*) from rated where final = 1),
                                                   (select count(*) from rated where final = 2), (select count(*) from rated where final = 3)) end,
               'with_evidence', case when (select count(*) from rated) >= v_k
                                     then (select count(*) from rated where evidence >= 3) end,
               'calib_changed', case when (select count(*) from rated where calibrated) >= v_k
                                     then (select count(*) from rated where changed) end,
               'raters', (select count(*) from raters),
               'rater_spread', case when (select count(*) from raters) >= 2
                                    then (select round(max(avg_rating) - min(avg_rating), 2) from raters) end,
               'by_group', hc_suppress((select j from grp_json), v_k)),
    'checkin', jsonb_build_object(
               'priorities', (select count(*) from pri_stat),
               'running_4w', (select count(*) from pri_stat where weeks = 4),
               'checkins_4w', (select count(*) from ck),
               'on_time', (select count(*) from ck where on_time)),
    'goals', jsonb_build_object(
               'teams', (select count(*) from outlets),
               'teams_with_target', (select count(*) from outlets where has_target)),
    'practice', (select coalesce(jsonb_agg(jsonb_build_object(
                   'team', team, 'area', area, 'priorities', priorities, 'running', running,
                   'checkin_rate', case when priorities > 0 then round(checkins::numeric / (priorities * 4) * 100) end,
                   'progress', progress) order by area, team), '[]'::jsonb) from outlets)
  ) into v_result;

  return v_result;
end;
$$;

revoke execute on function hc_suppress(jsonb, integer) from public, anon;
revoke execute on function hc_overview(text) from public, anon;
revoke execute on function guard_worker_is_demo() from public, anon;
grant execute on function hc_suppress(jsonb, integer) to authenticated;
grant execute on function hc_overview(text) to authenticated;
