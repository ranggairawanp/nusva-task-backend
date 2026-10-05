-- Komentar, mention, dan persetujuan tugas.
--
-- Keputusan desain:
-- 1. Komentar per tugas di tabel work_item_comments. Baca seluas tenant (sama
--    dengan work_items). Tulis hanya lewat RPC add_work_item_comment oleh
--    anggota tim tugas itu atau manajer+/eksekutif/HC. Mention disimpan sebagai
--    uuid[] worker, disaring ke tenant yang sama, maksimal 10.
-- 2. Riwayat persetujuan ditulis ke tabel yang sama dengan kind SUBMITTED,
--    APPROVED, CHANGES_REQUESTED, jadi utas komentar sekaligus jadi jejak
--    aktivitas tugas. Hanya kind COMMENT dan CHANGES_REQUESTED yang wajib isi.
-- 3. Persetujuan: work_items.requires_approval (diatur manajer tim atau
--    eksekutif/HC lewat set_work_item_approval). complete_work_item untuk tugas
--    seperti ini tidak langsung DONE: status jadi WAITING, approval_status
--    PENDING, dengan cek foto wajib dan audit yang sama seperti saat selesai.
--    review_work_item oleh manajer tim (bukan PIC tugas itu sendiri) memilih
--    APPROVE (status DONE, evidence dan angka Action Plan baru bertambah di
--    sini) atau REQUEST_CHANGES (wajib catatan, status kembali IN_PROGRESS).
-- 4. Kolom persetujuan hanya boleh diubah oleh RPC di atas. Pemilik tugas
--    punya hak update langsung lewat policy work_items_write, jadi trigger
--    guard_work_item_approval menolak perubahan kolom persetujuan di luar RPC
--    (penanda transaksi nusva.approval_rpc) dan menolak status DONE untuk
--    tugas yang wajib disetujui tapi belum APPROVED.
-- 5. Tidak ada DROP, REVOKE ALL, atau DELETE. complete_work_item diganti isinya
--    dengan tanda tangan yang sama.

create table work_item_comments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  work_item_id uuid not null references work_items(id) on delete cascade,
  author_id uuid not null references workers(id),
  kind text not null default 'COMMENT' check (kind in ('COMMENT','SUBMITTED','APPROVED','CHANGES_REQUESTED')),
  body text check (body is null or char_length(body) between 1 and 1000),
  mentions uuid[] not null default '{}',
  created_at timestamptz not null default now(),
  check (kind not in ('COMMENT','CHANGES_REQUESTED') or body is not null)
);
create index work_item_comments_item_idx on work_item_comments (work_item_id, created_at);
create index work_item_comments_mentions_idx on work_item_comments using gin (mentions);
alter table work_item_comments enable row level security;
grant select on work_item_comments to authenticated;
create policy tenant_isolation_select on work_item_comments for select
  using (tenant_id = current_tenant_id());

alter table work_items
  add column requires_approval boolean not null default false,
  add column approval_status text check (approval_status in ('PENDING','APPROVED','CHANGES_REQUESTED')),
  add column approved_by uuid references workers(id),
  add column approved_at timestamptz;

-- Seed contoh (sebelum trigger penjaga dibuat): rekap kas Rina wajib
-- disetujui, latihan kasir Dedi sudah dikirim dan menunggu persetujuan, dan
-- satu utas komentar di tugas upsell Rina.
update work_items set requires_approval = true
 where id in ('a0000000-0000-0000-0000-000000000007','a0000000-0000-0000-0000-000000000004');
update work_items set status = 'WAITING', approval_status = 'PENDING'
 where id = 'a0000000-0000-0000-0000-000000000004' and status <> 'DONE';

insert into work_item_comments (tenant_id, work_item_id, author_id, kind, body, mentions, created_at) values
  ('00000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000004', '60000000-0000-0000-0000-000000000002',
   'SUBMITTED', null, '{}', now() - interval '3 hours'),
  ('00000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000004', '60000000-0000-0000-0000-000000000002',
   'COMMENT', 'Kasir baru sudah praktik 3 kalimat di 10 transaksi, lancar di 8.', '{}', now() - interval '3 hours'),
  ('00000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000004',
   'COMMENT', '@Rina fokus ke paket kopi susu dulu, stok sirup aman sampai Kamis.', '{60000000-0000-0000-0000-000000000001}', now() - interval '2 hours'),
  ('00000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000001',
   'COMMENT', 'Siap, sampai jam 12 sudah 18 transaksi.', '{}', now() - interval '90 minutes');

-- Penjaga kolom persetujuan (keputusan 4).
create or replace function guard_work_item_approval()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_rpc boolean := coalesce(current_setting('nusva.approval_rpc', true), '') = 'on';
begin
  if not v_rpc and (
       new.requires_approval is distinct from old.requires_approval
    or new.approval_status is distinct from old.approval_status
    or new.approved_by is distinct from old.approved_by
    or new.approved_at is distinct from old.approved_at) then
    raise exception 'approval fields can only change through the approval flow';
  end if;
  if new.status = 'DONE' and old.status <> 'DONE'
     and new.requires_approval and new.approval_status is distinct from 'APPROVED' then
    raise exception 'approval required before this work item is done';
  end if;
  return new;
end;
$$;

create trigger trg_guard_work_item_approval
  before update on work_items
  for each row execute function guard_work_item_approval();

-- Cek yang sama dengan trigger syarat selesai (migration 020), dipakai saat
-- tugas dikirim untuk persetujuan.
create or replace function assert_work_item_completable(p_item work_items)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_missing integer;
  v_kind text;
begin
  select count(*) into v_missing from checklist_items
   where work_item_id = p_item.id and requires_photo and photo_path is null;
  if v_missing > 0 then
    raise exception 'photo required: % item(s) still need a photo', v_missing;
  end if;
  if p_item.template_id is not null then
    select kind into v_kind from recurring_templates where id = p_item.template_id;
    if v_kind = 'AUDIT' then
      select count(*) into v_missing from checklist_items
       where work_item_id = p_item.id and result is null;
      if v_missing > 0 then
        raise exception 'audit incomplete: % item(s) not rated yet', v_missing;
      end if;
    end if;
  end if;
end;
$$;

-- complete_work_item: isi sama dengan migration 010, ditambah cabang
-- persetujuan (keputusan 3).
create or replace function complete_work_item(p_work_item_id uuid)
returns work_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item work_items;
  v_actor uuid := current_worker_id();
  v_role text := current_worker_role();
begin
  select * into v_item from work_items
    where id = p_work_item_id and tenant_id = current_tenant_id();
  if v_item.id is null then
    raise exception 'work item not found';
  end if;
  if not (v_item.owner_id = v_actor or v_role in ('manager','executive','hc_admin')) then
    raise exception 'not authorized to complete this work item';
  end if;

  if v_item.requires_approval and v_item.status <> 'DONE'
     and v_item.approval_status is distinct from 'APPROVED' then
    if v_item.approval_status = 'PENDING' then
      raise exception 'already waiting for approval';
    end if;
    perform assert_work_item_completable(v_item);
    perform set_config('nusva.approval_rpc', 'on', true);
    update work_items
       set status = 'WAITING', approval_status = 'PENDING', approved_by = null, approved_at = null
     where id = p_work_item_id
    returning * into v_item;
    perform set_config('nusva.approval_rpc', 'off', true);
    insert into work_item_comments (tenant_id, work_item_id, author_id, kind)
    values (v_item.tenant_id, v_item.id, v_actor, 'SUBMITTED');
    return v_item;
  end if;

  update work_items set status = 'DONE'
    where id = p_work_item_id
    returning * into v_item;

  insert into evidence (tenant_id, work_item_id, type, payload, created_by)
  values (v_item.tenant_id, v_item.id, 'SYSTEM_EVENT',
          jsonb_build_object('event', 'work_item_completed', 'at', now()), v_actor);

  if v_item.driver_id is not null and v_item.qty is not null then
    update drivers set actual = actual + v_item.qty, version = version + 1
      where id = v_item.driver_id;
  end if;

  return v_item;
end;
$$;

-- Atur wajib persetujuan (manajer tim, eksekutif/HC).
create or replace function set_work_item_approval(p_work_item_id uuid, p_required boolean)
returns work_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item work_items;
  v_actor uuid := current_worker_id();
  v_role text := current_worker_role();
begin
  select * into v_item from work_items where id = p_work_item_id and tenant_id = current_tenant_id();
  if v_item.id is null then
    raise exception 'work item not found';
  end if;
  if not (v_role in ('executive','hc_admin')
          or (v_role = 'manager' and v_item.team_id = (select team_id from workers where id = v_actor))) then
    raise exception 'not authorized to change approval for this work item';
  end if;
  if v_item.status = 'DONE' then
    raise exception 'work item is already done';
  end if;
  if v_item.approval_status = 'PENDING' then
    raise exception 'cannot change approval while waiting for approval';
  end if;
  perform set_config('nusva.approval_rpc', 'on', true);
  update work_items
     set requires_approval = coalesce(p_required, false),
         approval_status = case when coalesce(p_required, false) then approval_status else null end
   where id = p_work_item_id
  returning * into v_item;
  perform set_config('nusva.approval_rpc', 'off', true);
  return v_item;
end;
$$;

-- Putusan persetujuan (manajer tim atau eksekutif/HC, bukan PIC sendiri).
create or replace function review_work_item(p_work_item_id uuid, p_decision text, p_note text default null)
returns work_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item work_items;
  v_actor uuid := current_worker_id();
  v_role text := current_worker_role();
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  select * into v_item from work_items where id = p_work_item_id and tenant_id = current_tenant_id();
  if v_item.id is null then
    raise exception 'work item not found';
  end if;
  if not (v_role in ('executive','hc_admin')
          or (v_role = 'manager' and v_item.team_id = (select team_id from workers where id = v_actor))) then
    raise exception 'not authorized to review this work item';
  end if;
  if v_item.owner_id = v_actor then
    raise exception 'not authorized to review your own work item';
  end if;
  if v_item.approval_status is distinct from 'PENDING' then
    raise exception 'work item is not waiting for approval';
  end if;
  if v_note is not null and char_length(v_note) > 1000 then
    raise exception 'note is too long';
  end if;

  perform set_config('nusva.approval_rpc', 'on', true);
  if p_decision = 'APPROVE' then
    update work_items
       set approval_status = 'APPROVED', approved_by = v_actor, approved_at = now(), status = 'DONE'
     where id = p_work_item_id
    returning * into v_item;
    perform set_config('nusva.approval_rpc', 'off', true);
    insert into evidence (tenant_id, work_item_id, type, payload, created_by)
    values (v_item.tenant_id, v_item.id, 'APPROVAL',
            jsonb_build_object('event', 'work_item_approved', 'at', now()), v_actor);
    if v_item.driver_id is not null and v_item.qty is not null then
      update drivers set actual = actual + v_item.qty, version = version + 1
        where id = v_item.driver_id;
    end if;
    insert into work_item_comments (tenant_id, work_item_id, author_id, kind, body)
    values (v_item.tenant_id, v_item.id, v_actor, 'APPROVED', v_note);
  elsif p_decision = 'REQUEST_CHANGES' then
    if v_note is null then
      raise exception 'a change request needs a note';
    end if;
    update work_items
       set approval_status = 'CHANGES_REQUESTED', status = 'IN_PROGRESS'
     where id = p_work_item_id
    returning * into v_item;
    perform set_config('nusva.approval_rpc', 'off', true);
    insert into work_item_comments (tenant_id, work_item_id, author_id, kind, body)
    values (v_item.tenant_id, v_item.id, v_actor, 'CHANGES_REQUESTED', v_note);
  else
    raise exception 'invalid decision';
  end if;
  return v_item;
end;
$$;

-- Komentar (keputusan 1).
create or replace function add_work_item_comment(p_work_item_id uuid, p_body text, p_mentions uuid[] default '{}')
returns work_item_comments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item work_items;
  v_actor uuid := current_worker_id();
  v_role text := current_worker_role();
  v_tenant uuid := current_tenant_id();
  v_body text := btrim(coalesce(p_body, ''));
  v_mentions uuid[];
  v_row work_item_comments;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  select * into v_item from work_items where id = p_work_item_id and tenant_id = v_tenant;
  if v_item.id is null then
    raise exception 'work item not found';
  end if;
  if not (v_role in ('manager','executive','hc_admin')
          or v_item.team_id = (select team_id from workers where id = v_actor)) then
    raise exception 'not authorized to comment on this work item';
  end if;
  if v_body = '' then
    raise exception 'comment is empty';
  end if;
  if char_length(v_body) > 1000 then
    raise exception 'comment is too long';
  end if;
  select coalesce(array_agg(distinct w.id), '{}') into v_mentions
    from workers w
   where w.tenant_id = v_tenant and w.id = any(coalesce(p_mentions, '{}'));
  if cardinality(v_mentions) > 10 then
    raise exception 'too many mentions';
  end if;

  insert into work_item_comments (tenant_id, work_item_id, author_id, kind, body, mentions)
  values (v_tenant, v_item.id, v_actor, 'COMMENT', v_body, v_mentions)
  returning * into v_row;
  return v_row;
end;
$$;

revoke execute on function set_work_item_approval(uuid, boolean) from public, anon;
revoke execute on function review_work_item(uuid, text, text) from public, anon;
revoke execute on function add_work_item_comment(uuid, text, uuid[]) from public, anon;
revoke execute on function assert_work_item_completable(work_items) from public, anon, authenticated;
grant execute on function set_work_item_approval(uuid, boolean) to authenticated;
grant execute on function review_work_item(uuid, text, text) to authenticated;
grant execute on function add_work_item_comment(uuid, text, uuid[]) to authenticated;
