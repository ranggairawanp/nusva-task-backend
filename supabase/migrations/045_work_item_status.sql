-- 045: perubahan status tugas dari layar: mulai kerjakan, menunggu pihak lain, kembali ke belum mulai, dan batalkan.
--
-- Status tugas sudah tujuh sejak 002 (PLANNED, READY, IN_PROGRESS, WAITING, BLOCKED, DONE, CANCELLED), tapi jalur tulis yang
-- ada hanya selesai (complete_work_item), kendala (raise_blocker, resolve_blocker), dan persetujuan. Migration ini menambah
-- satu RPC untuk sisanya, supaya angka "Dikerjakan" dan "Menunggu" di layar jujur dan Waiting tidak dicampur dengan Blocked
-- (WM-BR-008):
-- 1. work_items mendapat status_note (catatan status terakhir: siapa yang ditunggu, atau alasan batal), status_changed_at,
--    dan status_changed_by.
-- 2. set_work_item_status(p_work_item_id, p_status, p_note): hanya READY, IN_PROGRESS, WAITING, CANCELLED. Hak sama dengan
--    mengubah tugas (can_manage_work_item: pemilik, manajer tim tugas itu, eksekutif/HC). Tugas selesai atau dibatalkan tidak
--    bisa diubah (juga dijaga trigger 004), tugas yang menunggu persetujuan tidak bisa diubah statusnya lewat jalur ini.
--    WAITING wajib catatan, CANCELLED wajib alasan (paling panjang 500).
-- 3. Membatalkan: manajer tim, eksekutif, HC, atau karyawan untuk tugas yang dia buat sendiri (bukan tugas rutin dan bukan
--    tugas dari manajer). Kendala yang masih terbuka ikut ditutup. Tugas yang dibatalkan tidak dihapus.
-- 4. Tugas yang masih punya kendala terbuka tidak bisa dipindah ke status kerja lain sebelum kendalanya diselesaikan.
-- 5. Audit lewat trigger work_items yang sudah ada (log_audit_event); version dan updated_by naik lewat trigger 029 dan 041.
--    Tidak ada DROP, REVOKE ALL, atau DELETE.

alter table work_items
  add column if not exists status_note text,
  add column if not exists status_changed_at timestamptz,
  add column if not exists status_changed_by uuid references workers(id);

create or replace function set_work_item_status(p_work_item_id uuid, p_status text, p_note text default null)
returns work_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_role text := current_worker_role();
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_item work_items;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  if p_status is null or p_status not in ('READY', 'IN_PROGRESS', 'WAITING', 'CANCELLED') then
    raise exception 'invalid status';
  end if;
  select * into v_item from work_items where id = p_work_item_id and tenant_id = current_tenant_id() for update;
  if not found then
    raise exception 'work item not found';
  end if;
  if not can_manage_work_item(v_item.owner_id, v_item.team_id) then
    raise exception 'not authorized to change this work item';
  end if;
  if v_item.status in ('DONE', 'CANCELLED') then
    raise exception 'cannot edit a finished work item';
  end if;
  if v_item.approval_status = 'PENDING' then
    raise exception 'cannot edit while waiting for approval';
  end if;
  if char_length(coalesce(v_note, '')) > 500 then
    raise exception 'text is too long';
  end if;
  if p_status = 'WAITING' and v_note is null then
    raise exception 'waiting needs a note';
  end if;
  if p_status = 'CANCELLED' then
    if v_note is null then
      raise exception 'cancel needs a reason';
    end if;
    if not (v_role in ('manager', 'executive', 'hc_admin')
            or (v_item.creator_id = v_actor and v_item.template_id is null)) then
      raise exception 'not authorized to cancel this work item';
    end if;
    update blockers set status = 'RESOLVED', resolved_at = now()
     where work_item_id = v_item.id and status = 'OPEN';
  elsif exists (select 1 from blockers where work_item_id = v_item.id and status = 'OPEN') then
    raise exception 'resolve the blocker first';
  end if;

  update work_items
     set status = p_status,
         status_note = case when p_status in ('WAITING', 'CANCELLED') then v_note else null end,
         status_changed_at = now(),
         status_changed_by = v_actor
   where id = v_item.id
  returning * into v_item;
  return v_item;
end;
$$;

revoke execute on function set_work_item_status(uuid, text, text) from public;
revoke execute on function set_work_item_status(uuid, text, text) from anon;
grant execute on function set_work_item_status(uuid, text, text) to authenticated;
