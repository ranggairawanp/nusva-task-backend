-- 039: data kepegawaian untuk dashboard HC (kontrak dan turnover). Sampai 038 kedua baris itu di
-- halaman Talenta ditulis "Belum ada" karena sistem tidak punya tanggal masuk, jenis kontrak, atau
-- tanggal keluar. Migration ini menambahnya, dengan aturan privasi yang sama dengan hc_people().
--
-- 1. Tabel worker_employment (satu baris per pekerja): jenis kepegawaian (tetap, PKWT, masa percobaan),
--    tanggal masuk, tanggal akhir kontrak (wajib untuk PKWT dan masa percobaan, kosong untuk tetap),
--    tanggal keluar dan jenisnya (resign, kontrak berakhir, lainnya). Sengaja BUKAN kolom di workers:
--    policy SELECT workers seluas tenant, sedangkan data ini hanya boleh dibaca HC. RLS dinyalakan tanpa
--    policy dan hak tabel dicabut, jadi semua baca dan tulis lewat fungsi di bawah.
-- 2. set_worker_employment(): hanya hc_admin, satu tenant, validasi tanggal dan jenis di server. Eksekutif
--    hanya melihat angka agregat. Setiap perubahan tercatat di audit_log lewat trigger.
-- 3. list_worker_employment(): baris per pekerja untuk formulir HC (hanya hc_admin, tercatat READ).
-- 4. hc_workforce(): angka agregat untuk eksekutif dan HC. Populasi = pekerja yang datanya sudah diisi
--    dan masih aktif; di bawah tenants.hc_min_group semua angka ditahan, per area lewat hc_suppress().
--    Cakupan (berapa pekerja yang sudah diisi dari seluruh karyawan dan manajer) ikut dikirim supaya
--    layar tidak menampilkan data yang baru terisi sebagian seolah lengkap. Turnover 12 bulan =
--    jumlah yang keluar dalam 12 bulan dibagi rata-rata jumlah pekerja di awal dan di akhir periode.
--    Tidak ada nama atau baris per orang, dan tidak ada rincian per rating (jumlah yang keluar terlalu
--    kecil untuk dibagi tanpa membuka identitas).
-- 5. Risiko resign tetap tidak ada: butuh model dan data beberapa periode yang belum ada.
-- 6. Tidak ada DROP, REVOKE ALL pada fungsi lama, atau DELETE.

create table worker_employment (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  worker_id uuid not null unique references workers(id) on delete cascade,
  employment_type text not null check (employment_type in ('PERMANENT','FIXED_TERM','PROBATION')),
  joined_on date not null,
  contract_end date,
  exited_on date,
  exit_kind text check (exit_kind in ('RESIGN','CONTRACT_END','OTHER')),
  updated_by uuid references workers(id),
  updated_at timestamptz not null default now(),
  constraint worker_employment_contract_chk check (
    (employment_type = 'PERMANENT' and contract_end is null)
    or (employment_type in ('FIXED_TERM','PROBATION') and contract_end is not null and contract_end >= joined_on)),
  constraint worker_employment_exit_chk check (
    (exited_on is null and exit_kind is null)
    or (exited_on is not null and exit_kind is not null and exited_on >= joined_on))
);

create index idx_worker_employment_tenant on worker_employment(tenant_id);

alter table worker_employment enable row level security;
revoke all on worker_employment from anon, authenticated;

create trigger trg_audit_worker_employment after insert or update or delete on worker_employment
  for each row execute function log_audit_event();

create or replace function set_worker_employment(
  p_worker uuid, p_type text, p_joined date, p_contract_end date, p_exited date, p_exit_kind text)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_tenant uuid := current_tenant_id();
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_id uuid;
begin
  if current_worker_role() <> 'hc_admin' then
    raise exception 'not authorized to edit employment data';
  end if;
  if not exists (select 1 from workers where id = p_worker and tenant_id = v_tenant) then
    raise exception 'worker not found in this tenant';
  end if;
  if p_type is null or p_type not in ('PERMANENT','FIXED_TERM','PROBATION') then
    raise exception 'invalid employment type';
  end if;
  if p_joined is null then
    raise exception 'join date is required';
  end if;
  if p_joined > v_today then
    raise exception 'join date cannot be in the future';
  end if;
  if p_type = 'PERMANENT' and p_contract_end is not null then
    raise exception 'permanent employment has no contract end date';
  end if;
  if p_type in ('FIXED_TERM','PROBATION') and p_contract_end is null then
    raise exception 'contract end date is required';
  end if;
  if p_contract_end is not null and p_contract_end < p_joined then
    raise exception 'contract end is before join date';
  end if;
  if p_exited is not null then
    if p_exit_kind is null or p_exit_kind not in ('RESIGN','CONTRACT_END','OTHER') then
      raise exception 'exit kind is required';
    end if;
    if p_exited < p_joined then
      raise exception 'exit date is before join date';
    end if;
    if p_exited > v_today then
      raise exception 'exit date cannot be in the future';
    end if;
  elsif p_exit_kind is not null then
    raise exception 'exit kind needs an exit date';
  end if;

  insert into worker_employment (tenant_id, worker_id, employment_type, joined_on, contract_end, exited_on, exit_kind, updated_by, updated_at)
  values (v_tenant, p_worker, p_type, p_joined, p_contract_end, p_exited, p_exit_kind, current_worker_id(), now())
  on conflict (worker_id) do update
     set employment_type = excluded.employment_type, joined_on = excluded.joined_on,
         contract_end = excluded.contract_end, exited_on = excluded.exited_on,
         exit_kind = excluded.exit_kind, updated_by = excluded.updated_by, updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function list_worker_employment()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_tenant uuid := current_tenant_id();
begin
  if current_worker_role() <> 'hc_admin' then
    raise exception 'not authorized to view employment data';
  end if;
  insert into audit_log (tenant_id, actor_id, action, object_type, object_id, after)
  values (v_tenant, current_worker_id(), 'READ', 'worker_employment', v_tenant, '{}'::jsonb);
  return coalesce((select jsonb_agg(jsonb_build_object(
            'worker_id', e.worker_id, 'type', e.employment_type, 'joined_on', e.joined_on,
            'contract_end', e.contract_end, 'exited_on', e.exited_on, 'exit_kind', e.exit_kind,
            'updated_at', e.updated_at) order by e.worker_id)
          from worker_employment e where e.tenant_id = v_tenant), '[]'::jsonb);
end;
$$;

create or replace function hc_workforce()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_tenant uuid := current_tenant_id();
  v_k integer;
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_start date := ((now() at time zone 'Asia/Jakarta') - interval '12 months')::date;
  v_result jsonb;
begin
  if current_worker_role() not in ('executive','hc_admin') then
    raise exception 'not authorized to view the HC overview';
  end if;

  select hc_min_group into v_k from tenants where id = v_tenant;

  insert into audit_log (tenant_id, actor_id, action, object_type, object_id, after)
  values (v_tenant, current_worker_id(), 'READ', 'hc_workforce', v_tenant, '{}'::jsonb);

  with rec as (
    select e.*, upper(le.code) as area
      from worker_employment e
      join workers w on w.id = e.worker_id
      left join teams t on t.id = w.team_id
      left join business_units bu on bu.id = t.business_unit_id
      left join legal_entities le on le.id = bu.legal_entity_id
     where e.tenant_id = v_tenant and w.role in ('employee','manager')
  ),
  act as (select * from rec where exited_on is null or exited_on > v_today),
  agg as (
    select count(*) as n,
           count(*) filter (where employment_type = 'PERMANENT') as permanent,
           count(*) filter (where employment_type = 'FIXED_TERM') as fixed_term,
           count(*) filter (where employment_type = 'PROBATION') as probation,
           count(*) filter (where contract_end is not null and contract_end >= v_today and contract_end <= v_today + 30) as end30,
           count(*) filter (where contract_end is not null and contract_end > v_today + 30 and contract_end <= v_today + 60) as end60,
           count(*) filter (where contract_end is not null and contract_end > v_today + 60 and contract_end <= v_today + 90) as end90,
           count(*) filter (where contract_end is not null and contract_end < v_today) as overdue
      from act
  ),
  turn as (
    select count(*) filter (where exited_on > v_start and exited_on <= v_today) as exits,
           count(*) filter (where exited_on > v_start and exited_on <= v_today and exit_kind = 'RESIGN') as resigns,
           count(*) filter (where joined_on <= v_start and (exited_on is null or exited_on > v_start)) as head_start,
           count(*) filter (where joined_on <= v_today and (exited_on is null or exited_on > v_today)) as head_end
      from rec
  ),
  area_rows as (
    select a.area,
           count(*) as n,
           count(*) filter (where a.contract_end is not null and a.contract_end >= v_today and a.contract_end <= v_today + 90) as end90,
           count(*) filter (where a.contract_end is not null and a.contract_end < v_today) as overdue
      from act a where a.area is not null group by a.area
  ),
  area_turn as (
    select r.area,
           count(*) filter (where r.exited_on > v_start and r.exited_on <= v_today) as exits,
           count(*) filter (where r.joined_on <= v_start and (r.exited_on is null or r.exited_on > v_start)) as head_start,
           count(*) filter (where r.joined_on <= v_today and (r.exited_on is null or r.exited_on > v_today)) as head_end
      from rec r where r.area is not null group by r.area
  )
  select jsonb_build_object(
    'min_group', v_k,
    'as_of', v_today,
    'workers_total', (select count(*) from workers where tenant_id = v_tenant and role in ('employee','manager')),
    'n', (select n from agg),
    'contracts', case when (select n from agg) >= v_k then
        (select jsonb_build_object('permanent', permanent, 'fixed_term', fixed_term, 'probation', probation,
                'end30', end30, 'end60', end60, 'end90', end90, 'overdue', overdue) from agg) end,
    'turnover', case when (select n from agg) >= v_k then
        (select jsonb_build_object('exits', exits, 'resigns', resigns, 'head_start', head_start, 'head_end', head_end,
                'rate', case when head_start + head_end > 0
                             then round(exits::numeric * 200 / (head_start + head_end), 1) end) from turn) end,
    'by_area', hc_suppress((select coalesce(jsonb_agg(jsonb_build_object('group', ar.area, 'area', ar.area, 'n', ar.n,
                 'end90', ar.end90, 'overdue', ar.overdue, 'exits', atn.exits,
                 'rate', case when atn.head_start + atn.head_end > 0
                              then round(atn.exits::numeric * 200 / (atn.head_start + atn.head_end), 1) end) order by ar.area), '[]'::jsonb)
               from area_rows ar left join area_turn atn on atn.area = ar.area), v_k)
  ) into v_result;

  return v_result;
end;
$$;

revoke execute on function set_worker_employment(uuid, text, date, date, date, text) from public, anon;
revoke execute on function list_worker_employment() from public, anon;
revoke execute on function hc_workforce() from public, anon;
grant execute on function set_worker_employment(uuid, text, date, date, date, text) to authenticated;
grant execute on function list_worker_employment() to authenticated;
grant execute on function hc_workforce() to authenticated;
