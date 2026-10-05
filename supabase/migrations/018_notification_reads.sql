-- Status dibaca notifikasi, disinkronkan antarperangkat per karyawan.
--
-- Keputusan desain:
-- 1. Isi notifikasi TIDAK disimpan di server. Frontend menghitungnya dari data
--    yang sudah ada (tugas, handover, siklus penilaian, ringkasan unit), jadi
--    selalu sesuai keadaan terbaru dan tidak bisa basi. Yang perlu sinkron
--    antarperangkat hanya "notifikasi mana yang sudah dibaca".
-- 2. Kunci notifikasi (notif_key) dibuat frontend dan memuat keadaannya,
--    misalnya "employee:task:<uuid>:overdue:todo". Kalau keadaannya berubah
--    (tugas lain jadi terlambat, handover baru), kuncinya baru dan muncul lagi
--    sebagai belum dibaca. Server tidak perlu memahami isi kunci.
-- 3. Baca hanya baris milik sendiri (RLS). Tulis hanya lewat RPC
--    mark_notifications_read dengan identitas pemanggil, pola yang sama dengan
--    RPC lain di repo ini; tidak ada policy INSERT/UPDATE/DELETE untuk client.
-- 4. Tidak memakai audit trigger: status dibaca bukan data bisnis dan akan
--    membanjiri audit_log. Tidak ada pembersihan otomatis di RPC: perintah
--    DELETE di dalam fungsi membuat apply_migration tertahan konfirmasi
--    statement destruktif. Volumenya kecil (beberapa kunci per karyawan per
--    hari) dan frontend hanya membaca 500 kunci terbaru; pembersihan baris
--    lama menyusul sebagai tugas terjadwal terpisah.

create table notification_reads (
  tenant_id uuid not null references tenants(id),
  worker_id uuid not null references workers(id) on delete cascade,
  notif_key text not null check (char_length(notif_key) between 1 and 300),
  read_at timestamptz not null default now(),
  primary key (worker_id, notif_key)
);
create index notification_reads_worker_recent_idx on notification_reads (worker_id, read_at desc);
alter table notification_reads enable row level security;
-- Client hanya punya policy SELECT. Tanpa policy INSERT/UPDATE/DELETE, RLS
-- menolak semua tulisan langsung; satu-satunya jalan menulis adalah RPC di bawah.
-- Hak SELECT ditulis eksplisit supaya tidak bergantung default privileges.
grant select on notification_reads to authenticated;
create policy own_reads_select on notification_reads for select
  using (worker_id = current_worker_id() and tenant_id = current_tenant_id());

-- Tandai satu atau beberapa notifikasi sudah dibaca untuk pemanggil.
-- Mengembalikan jumlah kunci baru yang tercatat.
create or replace function mark_notifications_read(p_keys text[])
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_tenant uuid := current_tenant_id();
  v_count integer := 0;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  if p_keys is null or cardinality(p_keys) = 0 then
    return 0;
  end if;
  if cardinality(p_keys) > 200 then
    raise exception 'too many keys';
  end if;

  insert into notification_reads (tenant_id, worker_id, notif_key)
  select v_tenant, v_actor, k
  from (select distinct btrim(x) as k from unnest(p_keys) as x) s
  where k <> '' and char_length(k) <= 300
  on conflict (worker_id, notif_key) do nothing;
  get diagnostics v_count = row_count;

  return v_count;
end;
$$;

revoke execute on function mark_notifications_read(text[]) from public, anon;
grant execute on function mark_notifications_read(text[]) to authenticated;
