-- 029: ubah tugas dari aplikasi, dan catat siapa pengubah terakhir.
--
-- 1. Kolom work_items.updated_by: worker yang terakhir mengubah baris. Diisi trigger
--    trg_work_item_updater untuk SETIAP perubahan dari sesi login (ubah tugas, selesai,
--    kendala, persetujuan), jadi riwayat di detail tugas tidak lagi menulis "nama pengubah
--    belum tercatat" untuk perubahan baru. Perubahan tanpa sesi (cron penyegar data demo)
--    tidak menimpa nilai lama. Baris lama tetap null: aplikasi menulisnya apa adanya.
-- 2. RPC update_work_item(): nama (id/en), keterangan, deadline, prioritas tugas, dan PIC.
--    Aturan dipaksa di sini, bukan cuma di UI:
--    - hanya pemilik tugas, manajer tim tugas itu, atau eksekutif/HC (can_manage_work_item);
--    - tugas selesai atau dibatalkan tidak bisa diubah;
--    - tugas yang sedang menunggu persetujuan tidak bisa diubah (yang disetujui harus sama
--      dengan yang dikirim);
--    - nama tugas rutin mengikuti templatenya, jadi tidak bisa diganti per hari;
--    - ganti PIC hanya untuk manajer/eksekutif/HC, dan PIC baru harus satu tim dengan tugasnya
--      (tugas tidak pindah tim lewat jalur ini);
--    - Action Plan, Prioritas Utama, jenis, status, dan kolom persetujuan TIDAK disentuh.
--    Kalau nama Indonesia tidak berubah, judul lama (termasuk terjemahan Inggrisnya) dipertahankan.
-- 3. Tidak ada DROP, REVOKE ALL, atau DELETE.

alter table work_items add column updated_by uuid references workers(id);

create or replace function stamp_work_item_updater()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
begin
  if v_actor is not null then
    new.updated_by := v_actor;
  end if;
  return new;
end;
$$;

create trigger trg_work_item_updater
  before update on work_items
  for each row execute function stamp_work_item_updater();

create or replace function update_work_item(
  p_id uuid,
  p_title_id text,
  p_title_en text,
  p_description text,
  p_due_at timestamptz,
  p_priority_level text,
  p_owner_id uuid default null
)
returns work_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_role text := current_worker_role();
  v_tenant uuid := current_tenant_id();
  v_item work_items;
  v_title jsonb;
  v_owner uuid;
  v_owner_team uuid;
  v_desc text := nullif(btrim(coalesce(p_description, '')), '');
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;

  select * into v_item from work_items where id = p_id and tenant_id = v_tenant for update;
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

  if p_title_id is null or btrim(p_title_id) = '' then
    raise exception 'title is required';
  end if;
  if char_length(btrim(p_title_id)) > 200 or char_length(coalesce(p_title_en, '')) > 200 then
    raise exception 'title is too long';
  end if;
  if v_desc is not null and char_length(v_desc) > 1000 then
    raise exception 'description is too long';
  end if;
  if p_due_at is null then
    raise exception 'due date is required';
  end if;
  if p_priority_level not in ('LOW', 'NORMAL', 'HIGH', 'URGENT') then
    raise exception 'invalid priority level';
  end if;

  if btrim(p_title_id) = coalesce(v_item.title->>'id', '') then
    v_title := v_item.title;
  elsif v_item.template_id is not null then
    raise exception 'routine work title follows its template';
  else
    v_title := jsonb_build_object('id', btrim(p_title_id),
                                  'en', coalesce(nullif(btrim(p_title_en), ''), btrim(p_title_id)));
  end if;

  v_owner := coalesce(p_owner_id, v_item.owner_id);
  if v_owner <> v_item.owner_id then
    if v_role not in ('manager', 'executive', 'hc_admin') then
      raise exception 'not authorized to assign work to another worker';
    end if;
    select team_id into v_owner_team from workers where id = v_owner and tenant_id = v_tenant;
    if v_owner_team is distinct from v_item.team_id then
      raise exception 'not authorized to assign work to another team';
    end if;
  end if;

  update work_items
     set title = v_title,
         description = v_desc,
         due_at = p_due_at,
         priority_level = p_priority_level,
         owner_id = v_owner
   where id = p_id
  returning * into v_item;

  return v_item;
end;
$$;

revoke execute on function update_work_item(uuid, text, text, text, timestamptz, text, uuid) from public;
revoke execute on function update_work_item(uuid, text, text, text, timestamptz, text, uuid) from anon;
grant execute on function update_work_item(uuid, text, text, text, timestamptz, text, uuid) to authenticated;
