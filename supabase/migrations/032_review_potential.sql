-- 032: formulir potensi untuk manajer. Sampai 031, performance_reviews.potential hanya terisi dari
-- seed, tanpa pengisi dan tanpa alasan, padahal 9-box di dashboard HC (031) membacanya.
--
-- 1. Kolom baru di performance_reviews: potential_note (alasan, wajib saat diisi lewat RPC),
--    potential_at, potential_by. Nilai potensi dari seed tetap ada dengan potential_by null;
--    aplikasi menulisnya "pengisi tidak tercatat", bukan mengarang nama.
-- 2. RPC set_review_potential(): potensi 0 (Rendah), 1 (Sedang), 2 (Tinggi) plus alasan.
--    Aturan dipaksa di sini, bukan cuma di UI:
--    - manajer tim karyawan itu, atau eksekutif/HC (can_review_worker), bukan untuk diri sendiri;
--    - siklus masih terbuka;
--    - alasan wajib, maksimal 1.000 karakter, karena potensi tanpa dasar perilaku mudah bias;
--    - setelah rating dikalibrasi, hanya eksekutif/HC (peserta kalibrasi) yang boleh mengubah,
--      supaya posisi 9-box tidak bergeser diam-diam sesudah rapat kalibrasi.
--    Potensi tidak bergantung pada tahap self-assessment atau review manajer: dinilai terpisah
--    dari rating kinerja.
-- 3. Tulisan tercatat di audit_log lewat trigger performance_reviews (031).
-- 4. Tidak ada DROP, REVOKE ALL, atau DELETE.

alter table performance_reviews
  add column potential_note text check (potential_note is null or char_length(potential_note) <= 1000),
  add column potential_at timestamptz,
  add column potential_by uuid references workers(id);

create or replace function set_review_potential(p_review_id uuid, p_potential integer, p_note text)
returns performance_reviews
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_row performance_reviews;
  v_status text;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  select * into v_row from performance_reviews
   where id = p_review_id and tenant_id = current_tenant_id();
  if v_row.id is null then
    raise exception 'review not found';
  end if;
  if v_row.employee_id = v_actor then
    raise exception 'not authorized to review yourself';
  end if;
  if not can_review_worker(v_row.employee_id) then
    raise exception 'not authorized to review this employee';
  end if;
  select status into v_status from review_cycles where id = v_row.cycle_id;
  if v_status <> 'OPEN' then
    raise exception 'review cycle is closed';
  end if;
  if v_row.calib_rating is not null and current_worker_role() not in ('executive','hc_admin') then
    raise exception 'review already calibrated';
  end if;
  if p_potential is null or p_potential not between 0 and 2 then
    raise exception 'invalid potential';
  end if;
  if v_note is null then
    raise exception 'potential needs a reason';
  end if;
  if char_length(v_note) > 1000 then
    raise exception 'note is too long';
  end if;
  update performance_reviews
     set potential = p_potential, potential_note = v_note, potential_at = now(), potential_by = v_actor
   where id = p_review_id
  returning * into v_row;
  return v_row;
end;
$$;

revoke execute on function set_review_potential(uuid, integer, text) from public, anon;
grant execute on function set_review_potential(uuid, integer, text) to authenticated;
