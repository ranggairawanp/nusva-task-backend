-- Adds 2 demo accounts for the 'executive' and 'hc_admin' roles, which the
-- workers.role check constraint already allowed since migration 001 but which
-- migration 009's seed never populated (only employee and manager were seeded,
-- matching the named people/roles data.js actually implies).
--
-- Reason: the frontend's persona switcher (nusvapeople-task) has always shown
-- 4 personas (Employee, Manager, Executive, HC), and Pekerjaan Saya/Board Tim
-- becoming login-gated left Executive and HC with no account to log in as once
-- the login gate moves to the front of the whole app, ahead of route selection.
--
-- Explicitly synthesized (no data.js source, same disclosure pattern as the
-- manager account in 009): full names are role titles, not real people; both
-- are seeded tenant-wide with no team_id/position_id, since data.js has no
-- outlet-scoped executive or HC role and RLS already grants both roles
-- tenant-wide read/write via current_worker_role() in ('manager','executive','hc_admin').

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at,
  raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at,
  confirmation_token, email_change, email_change_token_new, recovery_token
) values
  ('00000000-0000-0000-0000-000000000000', '50000000-0000-0000-0000-000000000005', 'authenticated', 'authenticated',
   'eksekutif@demo.nusvapeople.local', crypt('NusvaDemo2026!', gen_salt('bf')), now(), now(),
   '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '50000000-0000-0000-0000-000000000006', 'authenticated', 'authenticated',
   'hc@demo.nusvapeople.local', crypt('NusvaDemo2026!', gen_salt('bf')), now(), now(),
   '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '');

insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
values
  (gen_random_uuid(), '50000000-0000-0000-0000-000000000005', '50000000-0000-0000-0000-000000000005',
   '{"sub":"50000000-0000-0000-0000-000000000005","email":"eksekutif@demo.nusvapeople.local"}'::jsonb, 'email', now(), now(), now()),
  (gen_random_uuid(), '50000000-0000-0000-0000-000000000006', '50000000-0000-0000-0000-000000000006',
   '{"sub":"50000000-0000-0000-0000-000000000006","email":"hc@demo.nusvapeople.local"}'::jsonb, 'email', now(), now(), now());

insert into workers (id, tenant_id, position_id, team_id, auth_user_id, full_name, role) values
  ('60000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000001', null, null, '50000000-0000-0000-0000-000000000005', 'Eksekutif ABC F&B Company', 'executive'),
  ('60000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000001', null, null, '50000000-0000-0000-0000-000000000006', 'HC ABC F&B Company', 'hc_admin');
