-- SOP dan audit outlet dengan foto.
--
-- Keputusan desain:
-- 1. Dibangun di atas tugas rutin (migration 016), bukan modul baru. Template
--    rutin punya jenis: CHECKLIST (seperti sebelumnya) atau AUDIT (tiap item
--    dinilai Sesuai/Temuan dan menghasilkan skor). Item checklist di
--    recurring_templates.checklist boleh membawa "photo": true, artinya item
--    itu wajib berfoto saat dikerjakan.
-- 2. Hasil per item disimpan di checklist_items (result PASS/FAIL, note,
--    photo_path). Penulisan tetap lewat policy checklist_items_write yang
--    sudah ada (pemilik tugas atau manajer+), tapi dijaga trigger:
--    requires_photo tidak bisa diubah setelah dibuat, temuan wajib catatan,
--    dan photo_path wajib berada di folder tugas itu sendiri.
-- 3. Tugas tidak bisa ditandai selesai kalau masih ada foto wajib yang belum
--    ada, atau (untuk audit) item yang belum dinilai. Dicek trigger BEFORE
--    UPDATE di work_items, jadi berlaku untuk semua jalur selesai
--    (complete_work_item satuan maupun aksi massal).
-- 4. Saat audit selesai, setiap temuan otomatis jadi tugas tindak lanjut
--    (prioritas HIGH, deadline akhir hari besok WIB, parent_work_id = audit),
--    ditugaskan ke manajer tim (atau ke PIC audit kalau tim belum punya
--    manajer). Skor tidak disimpan terpisah: dihitung dari checklist_items.
-- 5. Foto disimpan di bucket privat evidence-photos dengan path
--    {tenant_id}/{work_item_id}/{nama}.jpg, maksimal 2 MB, hanya JPEG
--    (frontend mengompres di perangkat ke sisi terpanjang 1.600 px, JPEG
--    0,72, dan encode ulang lewat canvas membuang metadata lokasi). Upload
--    hanya oleh pemilik tugas atau manajer+, baca seluas tenant lewat signed
--    URL. Tidak ada policy update atau hapus: foto bukti tidak bisa diganti
--    diam-diam.
-- 6. Tidak ada DROP, REVOKE ALL, atau DELETE (perintah destruktif membuat
--    apply_migration tertahan konfirmasi). Fungsi lama tidak diubah
--    tanda tangannya; template audit dibuat lewat RPC baru
--    create_routine_template_v2 supaya tidak ada overload yang ambigu.

alter table recurring_templates
  add column kind text not null default 'CHECKLIST' check (kind in ('CHECKLIST','AUDIT'));

alter table checklist_items
  add column requires_photo boolean not null default false,
  add column result text check (result in ('PASS','FAIL')),
  add column note text check (note is null or char_length(note) <= 500),
  add column photo_path text check (photo_path is null or char_length(photo_path) <= 300);

create index if not exists work_items_parent_idx on work_items (parent_work_id) where parent_work_id is not null;

-- Seed Outlet Dago: inspeksi higiene jadi audit lima item, rekap kas sore
-- mendapat checklist dengan foto slip setoran.
update recurring_templates
   set kind = 'AUDIT',
       title = '{"id":"Audit higiene dapur","en":"Kitchen hygiene audit"}',
       checklist = '[{"id":"Lantai dan saluran air bersih","en":"Floor and drains clean","photo":true},{"id":"Bahan berlabel tanggal","en":"Ingredients labelled with dates"},{"id":"Tidak ada bahan kedaluwarsa","en":"No expired ingredients","photo":true},{"id":"Wastafel cuci tangan lengkap","en":"Hand-wash sink stocked"},{"id":"Tempat sampah tertutup","en":"Bins closed"}]'
 where id = 'e0000000-0000-0000-0000-000000000005';

update recurring_templates
   set checklist = '[{"id":"Hitung kas laci","en":"Count till cash"},{"id":"Cocokkan dengan sistem kasir","en":"Reconcile with POS"},{"id":"Foto slip setoran","en":"Photograph the deposit slip","photo":true}]'
 where id = 'e0000000-0000-0000-0000-000000000004';

-- Instance yang sudah dibuat dan belum selesai diselaraskan dengan template
-- baru: judul diperbarui, item yang ada disesuaikan per posisi (judul dan
-- flag foto), item yang belum ada ditambahkan. Instance yang sudah selesai
-- tidak disentuh. Bagian ini berjalan sebelum trigger penjaga dibuat, karena
-- trigger itu melarang requires_photo diubah.
update work_items w
   set title = t.title
  from recurring_templates t
 where w.template_id = t.id and t.id = 'e0000000-0000-0000-0000-000000000005' and w.status <> 'DONE';

update checklist_items c
   set title = e.value - 'photo', requires_photo = coalesce((e.value->>'photo')::boolean, false)
  from work_items w
  join recurring_templates t on t.id = w.template_id
  cross join lateral jsonb_array_elements(t.checklist) with ordinality as e(value, ord)
 where c.work_item_id = w.id and c.position = e.ord
   and t.id in ('e0000000-0000-0000-0000-000000000004','e0000000-0000-0000-0000-000000000005')
   and w.status <> 'DONE';

insert into checklist_items (tenant_id, work_item_id, title, position, requires_photo)
select w.tenant_id, w.id, e.value - 'photo', e.ord::integer, coalesce((e.value->>'photo')::boolean, false)
  from work_items w
  join recurring_templates t on t.id = w.template_id
 cross join lateral jsonb_array_elements(t.checklist) with ordinality as e(value, ord)
 where t.id in ('e0000000-0000-0000-0000-000000000004','e0000000-0000-0000-0000-000000000005')
   and w.status <> 'DONE'
   and not exists (select 1 from checklist_items c where c.work_item_id = w.id and c.position = e.ord);

-- Penjaga baris checklist (lihat keputusan 2).
create or replace function guard_checklist_item()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and new.requires_photo is distinct from old.requires_photo then
    raise exception 'requires_photo cannot be changed';
  end if;
  if new.result = 'FAIL' and coalesce(btrim(new.note), '') = '' then
    raise exception 'a finding needs a note';
  end if;
  if new.photo_path is not null
     and new.photo_path not like (new.tenant_id::text || '/' || new.work_item_id::text || '/%') then
    raise exception 'photo path does not belong to this work item';
  end if;
  if new.result is not null then
    new.done := true;
  end if;
  return new;
end;
$$;

create trigger trg_guard_checklist_item
  before insert or update on checklist_items
  for each row execute function guard_checklist_item();

-- Syarat selesai (lihat keputusan 3).
create or replace function enforce_work_item_completion()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_kind text;
  v_missing integer;
begin
  if new.status <> 'DONE' or old.status = 'DONE' then
    return new;
  end if;
  select count(*) into v_missing from checklist_items
   where work_item_id = new.id and requires_photo and photo_path is null;
  if v_missing > 0 then
    raise exception 'photo required: % item(s) still need a photo', v_missing;
  end if;
  if new.template_id is not null then
    select kind into v_kind from recurring_templates where id = new.template_id;
    if v_kind = 'AUDIT' then
      select count(*) into v_missing from checklist_items
       where work_item_id = new.id and result is null;
      if v_missing > 0 then
        raise exception 'audit incomplete: % item(s) not rated yet', v_missing;
      end if;
    end if;
  end if;
  new.completed_at := coalesce(new.completed_at, now());
  return new;
end;
$$;

create trigger trg_enforce_work_item_completion
  before update on work_items
  for each row execute function enforce_work_item_completion();

-- Tindak lanjut otomatis dari temuan audit (lihat keputusan 4).
create or replace function create_audit_follow_ups()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_kind text;
  v_owner uuid;
  v_creator uuid;
  v_due timestamptz;
begin
  if new.status <> 'DONE' or old.status = 'DONE' or new.template_id is null then
    return new;
  end if;
  select kind into v_kind from recurring_templates where id = new.template_id;
  if v_kind is distinct from 'AUDIT' then
    return new;
  end if;
  select id into v_owner from workers
   where team_id = new.team_id and role = 'manager' and tenant_id = new.tenant_id
   order by full_name limit 1;
  v_owner := coalesce(v_owner, new.owner_id);
  v_creator := coalesce(current_worker_id(), new.owner_id);
  v_due := ((((now() at time zone 'Asia/Jakarta')::date) + 1) + time '17:00') at time zone 'Asia/Jakarta';

  insert into work_items (tenant_id, team_id, type, title, description, creator_id, owner_id,
                          status, priority_level, due_at, parent_work_id, qty)
  select new.tenant_id, new.team_id, 'TASK',
         jsonb_build_object(
           'id', 'Tindak lanjut: ' || coalesce(c.title->>'id', c.title->>'en', ''),
           'en', 'Follow up: ' || coalesce(c.title->>'en', c.title->>'id', '')),
         c.note, v_creator, v_owner, 'READY', 'HIGH', v_due, new.id, 1
    from checklist_items c
   where c.work_item_id = new.id and c.result = 'FAIL'
   order by c.position;
  return new;
end;
$$;

create trigger trg_create_audit_follow_ups
  after update on work_items
  for each row execute function create_audit_follow_ups();

-- Instance harian membawa flag foto dari template (keputusan 1). Isi sama
-- dengan 016, hanya baris insert checklist_items yang berubah.
create or replace function generate_routine_work(p_date date default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant uuid := current_tenant_id();
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_date date := coalesce(p_date, (now() at time zone 'Asia/Jakarta')::date);
  v_dow smallint := extract(isodow from coalesce(p_date, (now() at time zone 'Asia/Jakarta')::date))::smallint;
  v_count integer := 0;
  v_item_id uuid;
  v_due timestamptz;
  r record;
begin
  if v_tenant is null then
    raise exception 'not authenticated';
  end if;
  if v_date < v_today - 1 or v_date > v_today + 1 then
    raise exception 'date out of range';
  end if;

  for r in
    select t.*, s.starts_at as shift_start, s.ends_at as shift_end
    from recurring_templates t
    left join shifts s on s.id = t.shift_id
    where t.tenant_id = v_tenant and t.active and v_dow = any(t.days_of_week)
  loop
    v_due := (
      (v_date + case when r.shift_end is not null and r.shift_end <= r.shift_start then 1 else 0 end)
      + coalesce(r.shift_end, time '17:00')
    ) at time zone 'Asia/Jakarta';

    v_item_id := null;
    insert into work_items (tenant_id, team_id, type, title, creator_id, owner_id, status,
                            priority_level, due_at, template_id, shift_id, occurrence_date, qty)
    values (v_tenant, r.team_id, 'RECURRING_WORK', r.title, r.created_by, r.owner_id, 'READY',
            r.priority_level, v_due, r.id, r.shift_id, v_date, 1)
    on conflict (template_id, occurrence_date) where template_id is not null do nothing
    returning id into v_item_id;

    if v_item_id is not null then
      insert into checklist_items (tenant_id, work_item_id, title, position, requires_photo)
      select v_tenant, v_item_id, c.value - 'photo', c.ord::integer,
             coalesce((c.value->>'photo')::boolean, false)
      from jsonb_array_elements(r.checklist) with ordinality as c(value, ord);
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$$;

-- Template baru dengan jenis (CHECKLIST/AUDIT). Aturan sama dengan
-- create_routine_template di 016: manajer untuk timnya sendiri,
-- eksekutif/HC seluruh tenant, tim diturunkan dari PIC.
create or replace function create_routine_template_v2(
  p_title_id text,
  p_title_en text,
  p_shift_id uuid,
  p_days smallint[],
  p_owner_id uuid,
  p_checklist jsonb,
  p_priority_level text,
  p_kind text
)
returns recurring_templates
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_role text := current_worker_role();
  v_tenant uuid := current_tenant_id();
  v_team uuid;
  v_actor_team uuid;
  v_tpl recurring_templates;
  v_checklist jsonb;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  if v_role not in ('manager','executive','hc_admin') then
    raise exception 'not authorized to manage routine tasks';
  end if;
  if p_title_id is null or btrim(p_title_id) = '' then
    raise exception 'title is required';
  end if;
  if p_days is null or cardinality(p_days) = 0 then
    raise exception 'at least one day is required';
  end if;
  if coalesce(p_kind, 'CHECKLIST') not in ('CHECKLIST','AUDIT') then
    raise exception 'invalid template kind';
  end if;
  v_checklist := coalesce(p_checklist, '[]'::jsonb);
  if jsonb_typeof(v_checklist) <> 'array' or jsonb_array_length(v_checklist) > 30 then
    raise exception 'checklist must be an array of at most 30 items';
  end if;
  if p_kind = 'AUDIT' and jsonb_array_length(v_checklist) = 0 then
    raise exception 'an audit needs at least one item';
  end if;

  select team_id into v_team from workers where id = p_owner_id and tenant_id = v_tenant;
  if v_team is null then
    raise exception 'owner has no team';
  end if;
  if v_role = 'manager' then
    select team_id into v_actor_team from workers where id = v_actor;
    if v_actor_team is distinct from v_team then
      raise exception 'not authorized to manage routine tasks for another team';
    end if;
  end if;
  if p_shift_id is not null and not exists (select 1 from shifts where id = p_shift_id and team_id = v_team) then
    raise exception 'shift does not belong to this team';
  end if;

  insert into recurring_templates (tenant_id, team_id, title, shift_id, days_of_week, owner_id,
                                   checklist, priority_level, created_by, kind)
  values (
    v_tenant, v_team,
    jsonb_build_object('id', btrim(p_title_id), 'en', coalesce(nullif(btrim(p_title_en), ''), btrim(p_title_id))),
    p_shift_id, (select array_agg(distinct d order by d) from unnest(p_days) d),
    p_owner_id, v_checklist, coalesce(p_priority_level, 'NORMAL'), v_actor, coalesce(p_kind, 'CHECKLIST')
  )
  returning * into v_tpl;

  perform generate_routine_work();
  return v_tpl;
end;
$$;

revoke execute on function create_routine_template_v2(text, text, uuid, smallint[], uuid, jsonb, text, text) from public, anon;
grant execute on function create_routine_template_v2(text, text, uuid, smallint[], uuid, jsonb, text, text) to authenticated;

-- Bucket foto bukti (keputusan 5).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('evidence-photos', 'evidence-photos', false, 2097152, array['image/jpeg'])
on conflict (id) do nothing;

create policy evidence_photos_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'evidence-photos'
    and (storage.foldername(name))[1] = public.current_tenant_id()::text
    and exists (
      select 1 from public.work_items w
       where w.id::text = (storage.foldername(name))[2]
         and w.tenant_id = public.current_tenant_id()
         and (w.owner_id = public.current_worker_id()
              or public.current_worker_role() in ('manager','executive','hc_admin'))
    )
  );

create policy evidence_photos_select on storage.objects for select to authenticated
  using (
    bucket_id = 'evidence-photos'
    and (storage.foldername(name))[1] = public.current_tenant_id()::text
  );
