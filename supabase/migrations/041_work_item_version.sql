-- 041: kunci versi saat mengubah tugas, supaya perubahan orang lain tidak tertimpa diam-diam.
--
-- Masalah yang ditutup: dua orang membuka formulir ubah tugas yang sama (misalnya karyawan dan
-- manajernya). Yang menyimpan belakangan menimpa isian yang menyimpan duluan tanpa ada yang tahu.
--
-- 1. Kolom work_items.version (ada sejak migration 002, selama ini selalu 1) sekarang dijaga server:
--    trigger trg_work_item_version menaikkannya satu setiap kali isi baris berubah, dari jalur mana
--    pun (ubah tugas, selesai, kendala, persetujuan, cron data demo). Kolom yang hanya mencatat
--    perubahan (version, updated_at, updated_by) tidak dihitung, jadi UPDATE tanpa perubahan isi
--    tidak menaikkan versi. Nilai version yang dikirim klien selalu diabaikan.
-- 2. RPC update_work_item() versi baru dengan p_expected_version (wajib, tanpa nilai bawaan, supaya
--    tidak bentrok dengan versi lama saat dipanggil lewat nama argumen). Ia mengunci baris, memeriksa
--    hak ubah lebih dulu (supaya penolakan versi tidak membocorkan apa pun ke yang tidak berhak), lalu
--    menolak dengan 'work item was changed by someone else' kalau versinya sudah berbeda. Kalau sama,
--    ia memanggil versi lama sehingga semua aturan 029 tetap satu sumber.
-- 3. Versi lama update_work_item() (tanpa p_expected_version) tetap ada, supaya aplikasi versi
--    sebelumnya tetap jalan sampai versi baru terpasang.
-- 4. Tidak ada DROP, REVOKE ALL, atau DELETE.

create or replace function bump_work_item_version()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if (to_jsonb(new) - 'version' - 'updated_at' - 'updated_by')
     is distinct from (to_jsonb(old) - 'version' - 'updated_at' - 'updated_by') then
    new.version := old.version + 1;
  else
    new.version := old.version;
  end if;
  return new;
end;
$$;

create trigger trg_work_item_version
  before update on work_items
  for each row execute function bump_work_item_version();

create or replace function update_work_item(
  p_id uuid,
  p_title_id text,
  p_title_en text,
  p_description text,
  p_due_at timestamptz,
  p_priority_level text,
  p_expected_version integer,
  p_owner_id uuid default null
)
returns work_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant uuid := current_tenant_id();
  v_item work_items;
begin
  if current_worker_id() is null then
    raise exception 'not authenticated';
  end if;
  if p_expected_version is null then
    raise exception 'expected version is required';
  end if;

  select * into v_item from work_items where id = p_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'work item not found';
  end if;
  if not can_manage_work_item(v_item.owner_id, v_item.team_id) then
    raise exception 'not authorized to change this work item';
  end if;
  if v_item.version <> p_expected_version then
    raise exception 'work item was changed by someone else';
  end if;

  return update_work_item(p_id, p_title_id, p_title_en, p_description, p_due_at, p_priority_level, p_owner_id);
end;
$$;

revoke execute on function update_work_item(uuid, text, text, text, timestamptz, text, integer, uuid) from public;
revoke execute on function update_work_item(uuid, text, text, text, timestamptz, text, integer, uuid) from anon;
grant execute on function update_work_item(uuid, text, text, text, timestamptz, text, integer, uuid) to authenticated;
