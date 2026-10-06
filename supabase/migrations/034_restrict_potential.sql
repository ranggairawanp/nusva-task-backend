-- 034: potensi tidak terbaca karyawan. Sampai 033, RLS performance_reviews membolehkan karyawan membaca
-- barisnya sendiri SELURUHNYA, termasuk potensi dan alasan dari manajer. Potensi adalah penilaian
-- manajer untuk perencanaan talenta (9-box, suksesi), bukan umpan balik kinerja, jadi tidak dibuka
-- ke karyawan yang dinilai.
--
-- 1. Hak SELECT authenticated pada performance_reviews diganti per kolom: semua kolom KECUALI
--    potential, potential_note, potential_at, potential_by. RLS baris tetap seperti 022. Akses anon
--    dicabut (sudah tertutup RLS, sekarang juga di tingkat hak). Kolom baru di tabel ini di masa depan
--    wajib diberi GRANT SELECT kolom secara eksplisit, kalau tidak aplikasi tidak bisa membacanya.
-- 2. RPC review_potentials(p_cycle_id): satu-satunya jalur baca potensi. Hanya baris yang boleh
--    dinilai pemanggil (can_review_worker: manajer tim karyawan itu, eksekutif, HC) dan bukan baris
--    pemanggil sendiri. Karyawan selalu menerima daftar kosong.
-- 3. submit_self_assessment (dipanggil karyawan) mengosongkan kolom potensi di nilai baliknya.
--    RPC tulis lain hanya bisa dipanggil penilai (can_review_worker), jadi tidak perlu diubah.
-- 4. hc_people(), hc_overview(), hc_transparency() security definer dan hanya mengeluarkan angka
--    agregat; audit_log (berisi salinan baris) hanya terbaca HC sejak 027.
-- 5. Tidak ada DROP, REVOKE ALL, atau DELETE. Yang dicabut hanya SELECT tingkat tabel, diganti
--    SELECT tingkat kolom.

revoke select on performance_reviews from authenticated, anon;
grant select (id, tenant_id, cycle_id, employee_id,
              self_rating, self_note, self_at,
              mgr_rating, mgr_note, mgr_at, mgr_by,
              calib_rating, calib_note, calib_at, calib_by)
  on performance_reviews to authenticated;

create or replace function review_potentials(p_cycle_id uuid)
returns table (review_id uuid, potential smallint, note text, set_at timestamptz, set_by_name text)
language sql
stable
security definer
set search_path = public
as $$
  select pr.id, pr.potential, pr.potential_note, pr.potential_at, w.full_name
    from performance_reviews pr
    left join workers w on w.id = pr.potential_by
   where pr.tenant_id = current_tenant_id()
     and pr.cycle_id = p_cycle_id
     and current_worker_id() is not null
     and pr.employee_id <> current_worker_id()
     and can_review_worker(pr.employee_id);
$$;

revoke execute on function review_potentials(uuid) from public, anon;
grant execute on function review_potentials(uuid) to authenticated;

create or replace function submit_self_assessment(p_review_id uuid, p_rating integer, p_note text default null)
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
  if v_row.employee_id <> v_actor then
    raise exception 'not authorized to fill this self-assessment';
  end if;
  select status into v_status from review_cycles where id = v_row.cycle_id;
  if v_status <> 'OPEN' then
    raise exception 'review cycle is closed';
  end if;
  if v_row.mgr_rating is not null then
    raise exception 'manager review already submitted';
  end if;
  if p_rating is null or p_rating not between 0 and 3 then
    raise exception 'invalid rating';
  end if;
  if v_note is not null and char_length(v_note) > 1000 then
    raise exception 'note is too long';
  end if;
  update performance_reviews
     set self_rating = p_rating, self_note = v_note, self_at = now()
   where id = p_review_id
  returning * into v_row;
  -- karyawan tidak menerima kolom potensi lewat nilai balik
  v_row.potential := null;
  v_row.potential_note := null;
  v_row.potential_at := null;
  v_row.potential_by := null;
  return v_row;
end;
$$;
