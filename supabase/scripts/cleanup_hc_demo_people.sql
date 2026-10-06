-- Hapus data demo dashboard HC dari migration 028. TIDAK dijalankan otomatis.
-- Jalankan manual (SQL editor Supabase, satu transaksi) kalau data demo sudah tidak dibutuhkan,
-- misalnya sebelum tenant ini dipakai untuk data sungguhan. Data lain tidak tersentuh:
-- semua baris dipilih lewat workers.is_demo, id template e1..., atau check-in demo minggu ke-4.

begin;

delete from priority_checkins
 where id in (select checkin_id from demo_checkin_anchors where week_offset = 4)
   and priority_id in ('80000000-0000-0000-0000-000000000001', '80000000-0000-0000-0000-000000000002',
                       '81000000-0000-0000-0000-000000000003', '81000000-0000-0000-0000-000000000005',
                       '81000000-0000-0000-0000-000000000006', '81000000-0000-0000-0000-000000000007');

delete from work_items where owner_id in (select id from workers where is_demo);
delete from recurring_templates
 where id in ('e1000000-0000-0000-0000-000000000002', 'e1000000-0000-0000-0000-000000000003',
              'e1000000-0000-0000-0000-000000000004')
   and not exists (select 1 from work_items w where w.template_id = recurring_templates.id);
delete from performance_reviews where employee_id in (select id from workers where is_demo);

create temporary table hc_demo_auth as select auth_user_id from workers where is_demo;
delete from workers where is_demo;
delete from auth.identities where user_id in (select auth_user_id from hc_demo_auth);
delete from auth.users where id in (select auth_user_id from hc_demo_auth);

commit;
