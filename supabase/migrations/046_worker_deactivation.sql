-- 046: menonaktifkan karyawan yang keluar, dengan pengalihan tugas (WM-BR-014).
--
-- Sebelumnya tidak ada status aktif di workers: karyawan yang resign tetap bisa masuk, tetap muncul di pilihan PIC, dan tugas
-- aktifnya tertinggal tanpa orang yang mengerjakan. Migration ini:
-- 1. workers mendapat deactivated_at, deactivated_by, dan deactivation_note (catatan operasional, bukan alasan keluar; jenis dan
--    tanggal keluar tetap di worker_employment yang hanya terbaca HC, migration 039).
-- 2. current_tenant_id(), current_worker_id(), dan current_worker_role() hanya mengenali pekerja aktif. Akibatnya akun yang
--    dinonaktifkan tidak bisa membaca apa pun (RLS memakai current_tenant_id()) dan semua RPC menjawab 'not authenticated',
--    walaupun sesi login lamanya belum kedaluwarsa.
-- 3. RPC deactivate_worker(p_worker, p_reassign_to, p_note): hanya eksekutif dan HC, tidak untuk diri sendiri. Semua tugas yang
--    belum selesai atau dibatalkan dan semua template tugas rutin milik orang itu dialihkan ke satu orang aktif di tim yang sama
--    (wajib kalau ada yang perlu dialihkan), lalu orangnya dinonaktifkan. Mengembalikan jumlah yang dialihkan.
-- 4. RPC reactivate_worker(p_worker): hanya eksekutif dan HC. Tugas tidak dikembalikan otomatis.
-- 5. Trigger menolak tugas aktif dan template rutin yang ditugaskan ke pekerja nonaktif, dari jalur mana pun.
-- 6. Perubahan workers kini tercatat di audit_log lewat log_audit_event(). Tidak ada DROP, REVOKE ALL, atau DELETE.

alter table workers
  add column if not exists deactivated_at timestamptz,
  add column if not exists deactivated_by uuid references workers(id),
  add column if not exists deactivation_note text;

create or replace function current_tenant_id()
returns uuid as $$
  select tenant_id from workers where auth_user_id = auth.uid() and deactivated_at is null limit 1;
$$ language sql stable security definer set search_path = public;

create or replace function current_worker_id()
returns uuid as $$
  select id from workers where auth_user_id = auth.uid() and deactivated_at is null limit 1;
$$ language sql stable security definer set search_path = public;

create or replace function current_worker_role()
returns text as $$
  select role from workers where auth_user_id = auth.uid() and deactivated_at is null limit 1;
$$ language sql stable security definer set search_path = public;

create or replace function reject_inactive_owner()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if (tg_op = 'INSERT' or new.owner_id is distinct from old.owner_id)
     and coalesce(to_jsonb(new)->>'status', '') not in ('DONE', 'CANCELLED')
     and exists (select 1 from workers where id = new.owner_id and deactivated_at is not null) then
    raise exception 'worker is inactive';
  end if;
  return new;
end;
$$;

create trigger trg_reject_inactive_owner_work
  before insert or update of owner_id on work_items
  for each row execute function reject_inactive_owner();

create trigger trg_reject_inactive_owner_template
  before insert or update of owner_id on recurring_templates
  for each row execute function reject_inactive_owner();

create trigger trg_audit_workers
  after insert or update or delete on workers
  for each row execute function log_audit_event();

create or replace function deactivate_worker(p_worker uuid, p_reassign_to uuid, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_tenant uuid := current_tenant_id();
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_w workers;
  v_to workers;
  v_work int;
  v_tpl int;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  if current_worker_role() not in ('executive', 'hc_admin') then
    raise exception 'not authorized to deactivate workers';
  end if;
  select * into v_w from workers where id = p_worker and tenant_id = v_tenant for update;
  if not found then
    raise exception 'worker not found';
  end if;
  if v_w.id = v_actor then
    raise exception 'cannot deactivate yourself';
  end if;
  if v_w.deactivated_at is not null then
    raise exception 'worker is already inactive';
  end if;
  if char_length(coalesce(v_note, '')) > 500 then
    raise exception 'text is too long';
  end if;

  select count(*) into v_work from work_items where owner_id = v_w.id and status not in ('DONE', 'CANCELLED');
  select count(*) into v_tpl from recurring_templates where owner_id = v_w.id;

  if p_reassign_to is not null then
    select * into v_to from workers where id = p_reassign_to and tenant_id = v_tenant;
    if not found then
      raise exception 'worker not found';
    end if;
    if v_to.id = v_w.id then
      raise exception 'invalid reassign target';
    end if;
    if v_to.deactivated_at is not null then
      raise exception 'worker is inactive';
    end if;
    if v_w.team_id is not null and v_to.team_id is distinct from v_w.team_id then
      raise exception 'reassign target must be in the same team';
    end if;
    update work_items set owner_id = v_to.id where owner_id = v_w.id and status not in ('DONE', 'CANCELLED');
    update recurring_templates set owner_id = v_to.id where owner_id = v_w.id;
  elsif v_work > 0 or v_tpl > 0 then
    raise exception 'reassign target is required';
  end if;

  update workers
     set deactivated_at = now(), deactivated_by = v_actor, deactivation_note = v_note
   where id = v_w.id;

  return jsonb_build_object('work', v_work, 'templates', v_tpl, 'to', v_to.id);
end;
$$;

create or replace function reactivate_worker(p_worker uuid)
returns workers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_w workers;
begin
  if current_worker_id() is null then
    raise exception 'not authenticated';
  end if;
  if current_worker_role() not in ('executive', 'hc_admin') then
    raise exception 'not authorized to deactivate workers';
  end if;
  update workers set deactivated_at = null, deactivated_by = null, deactivation_note = null
   where id = p_worker and tenant_id = current_tenant_id() and deactivated_at is not null
  returning * into v_w;
  if not found then
    raise exception 'worker not found';
  end if;
  return v_w;
end;
$$;

revoke execute on function deactivate_worker(uuid, uuid, text) from public;
revoke execute on function deactivate_worker(uuid, uuid, text) from anon;
grant execute on function deactivate_worker(uuid, uuid, text) to authenticated;
revoke execute on function reactivate_worker(uuid) from public;
revoke execute on function reactivate_worker(uuid) from anon;
grant execute on function reactivate_worker(uuid) to authenticated;
