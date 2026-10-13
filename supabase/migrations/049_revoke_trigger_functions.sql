-- 049: fungsi trigger tidak lagi terbuka lewat API.
--
-- Postgres memberi hak EXECUTE ke PUBLIC untuk setiap fungsi baru, jadi semua fungsi trigger di skema public ikut tampil
-- sebagai /rest/v1/rpc/<nama> untuk anon dan authenticated. Pemanggilan langsungnya memang ditolak Postgres (fungsi trigger
-- hanya bisa jalan sebagai trigger), tapi dua di antaranya SECURITY DEFINER dan bisa dipanggil anon menurut linter keamanan
-- Supabase (add_worker_to_open_cycles, create_audit_follow_ups). Migration ini mencabut EXECUTE dari PUBLIC, anon, dan
-- authenticated untuk SEMUA fungsi trigger di skema public, termasuk yang dibuat nanti selama migration ini dijalankan ulang.
--
-- Trigger tetap jalan: hak EXECUTE fungsi trigger hanya diperiksa saat CREATE TRIGGER, bukan saat trigger menyala. Sudah diuji
-- dengan transaksi yang dibatalkan: ubah status, selesai, checklist, komentar, ketergantungan, dan tambah anggota tetap memicu
-- triggernya (versi naik, pengubah tercatat, audit tercatat) setelah hak dicabut.
--
-- Fungsi pembantu yang dipakai policy RLS (current_tenant_id, current_worker_id, current_worker_role, can_manage_work_item,
-- can_review_worker, kpi_visible_ids, can_link_initiative) sengaja TIDAK dicabut: policy berjalan dengan peran pemanggil, jadi
-- authenticated tetap butuh EXECUTE. Tidak ada DROP, REVOKE ALL, atau DELETE.

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prorettype = 'trigger'::regtype
  loop
    execute format('revoke execute on function %s from public', f.sig);
    execute format('revoke execute on function %s from anon', f.sig);
    execute format('revoke execute on function %s from authenticated', f.sig);
  end loop;
end;
$$;
