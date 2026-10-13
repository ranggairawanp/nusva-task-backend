-- Ganti password akun demo yang bisa login. TIDAK dijalankan otomatis dan tidak berisi password apa pun.
--
-- Repo ini publik, jadi password tidak pernah ditulis di sini atau di migration. Migration 009, 013, dan 023 masih memuat
-- password seed lama sebagai riwayat; password itu sudah diganti 13 Oktober 2026 dan tidak berlaku lagi.
--
-- Cara pakai:
-- 1. Buat hash bcrypt di komputer sendiri, supaya teks password tidak pernah masuk ke log query database. Contoh:
--      python3 -c "import bcrypt,getpass;print(bcrypt.hashpw(getpass.getpass().encode(),bcrypt.gensalt(10,b'2a')).decode())"
-- 2. Tempel hash itu menggantikan <HASH_BCRYPT> di bawah, lalu jalankan di SQL editor Supabase.
-- 3. Bagikan password barunya lewat jalur pribadi, bukan di repo, issue, atau layar aplikasi.
--
-- Yang diganti hanya akun demo yang memang dipakai login (sudah pernah punya password yang bisa dipakai). Karyawan demo
-- dashboard HC dari migration 028 (`workers.is_demo`) sengaja dilewati karena memang tidak bisa login. Sesi yang sedang
-- terbuka tidak ikut diputus; kalau perlu, putus lewat Authentication > Users di dashboard Supabase.

update auth.users u
   set encrypted_password = '<HASH_BCRYPT>',
       updated_at = now()
 where u.email like '%@demo.nusvapeople.local'
   and exists (select 1 from public.workers w where w.auth_user_id = u.id and not w.is_demo)
   and '<HASH_BCRYPT>' like '$2a$%';
