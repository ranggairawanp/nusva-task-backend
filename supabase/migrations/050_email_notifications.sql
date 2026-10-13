-- 050: notifikasi email lewat Resend.
--
-- Tujuannya memberi tahu orang saat ada yang perlu dia kerjakan, bukan mengejar pemakaian aplikasi. Karena itu:
-- 1. Hanya empat kejadian yang menghasilkan email, semuanya ditujukan ke satu orang yang memang perlu bertindak:
--    ASSIGNED (tugas baru atau dialihkan ke Anda oleh orang lain), MENTION (disebut di komentar), APPROVAL_REQUEST (PIC minta
--    persetujuan, ke manajer tim), APPROVAL_DECIDED (tugas disetujui atau perlu revisi, ke PIC). Ditambah DIGEST: ringkasan pagi
--    deadline hari ini dan tugas terlambat, mati bawaan dan hanya dikirim kalau ada isinya.
-- 2. Email hanya memuat nama tugas, nama orang yang memicu, dan deadline. Isi komentar dan catatan revisi tidak pernah dikirim.
-- 3. Jam tenang 21.00 sampai 06.00 WIB: email yang muncul di jam itu ditahan sampai 06.00 (email_not_before). Pengirim menggabungkan
--    semua email yang tertunda untuk satu orang menjadi satu email per putaran (tiap 5 menit).
-- 4. Tiap orang mengatur sendiri lewat notification_prefs (RPC set_notification_prefs); bawaan nyala untuk empat kejadian dan mati
--    untuk ringkasan pagi. Preferensi dibaca saat mengirim, jadi mematikan berlaku juga untuk email yang belum terkirim.
-- 5. Antrean email_outbox diisi trigger (jalur mana pun, termasuk RPC lama), tidak bisa dibaca atau ditulis langsung dari aplikasi
--    (RLS tanpa policy). Pengirim adalah Edge Function notify_send yang dipanggil pg_cron lewat pg_net dengan rahasia acak yang
--    dibuat di Vault dan tidak pernah keluar dari database: fungsi memeriksanya lewat notify_secret_ok().
-- 6. Alamat yang tidak bisa menerima email (akun demo @demo.nusvapeople.local, akun tanpa email, pekerja nonaktif) dilewati dengan
--    alasan tercatat, bukan dikirim. Email yang tidak terkirim 48 jam ditandai kedaluwarsa supaya antrean tidak menumpuk.
-- Tidak ada DROP, REVOKE ALL, atau DELETE.

create extension if not exists pg_net;

create table if not exists notification_prefs (
  worker_id uuid primary key references workers(id),
  tenant_id uuid not null references tenants(id),
  email_assigned boolean not null default true,
  email_mention boolean not null default true,
  email_approval boolean not null default true,
  email_digest boolean not null default false,
  lang text not null default 'id' check (lang in ('id', 'en')),
  updated_at timestamptz not null default now()
);
alter table notification_prefs enable row level security;
create policy notification_prefs_own on notification_prefs for select using (worker_id = current_worker_id());

create table if not exists email_outbox (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  worker_id uuid not null references workers(id),
  kind text not null check (kind in ('ASSIGNED', 'MENTION', 'APPROVAL_REQUEST', 'APPROVAL_DECIDED', 'DIGEST')),
  work_item_id uuid references work_items(id),
  actor_id uuid references workers(id),
  payload jsonb not null default '{}'::jsonb,
  dedupe_key text unique,
  not_before timestamptz not null default now(),
  status text not null default 'PENDING' check (status in ('PENDING', 'SENDING', 'SENT', 'SKIPPED', 'FAILED')),
  attempts integer not null default 0,
  skip_reason text,
  error text,
  sent_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists idx_email_outbox_due on email_outbox(status, not_before);
create index if not exists idx_email_outbox_worker on email_outbox(worker_id, created_at desc);
alter table email_outbox enable row level security;

-- Satu baris: hasil putaran pengirim terakhir, supaya layar bisa menulis jujur apakah email sudah aktif di server.
create table if not exists notify_health (
  id integer primary key default 1 check (id = 1),
  last_run_at timestamptz,
  last_status text check (last_status in ('ok', 'not_configured', 'failing')),
  last_error text
);
alter table notify_health enable row level security;
insert into notify_health (id) values (1) on conflict (id) do nothing;

-- Rahasia acak untuk panggilan pg_cron ke Edge Function, dibuat dan disimpan di Vault.
select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'notify_cron_secret', 'Rahasia panggilan pg_cron ke notify_send')
 where not exists (select 1 from vault.secrets where name = 'notify_cron_secret');

-- Jam tenang 21.00 sampai 06.00 WIB.
create or replace function email_not_before(p timestamptz default now())
returns timestamptz
language sql
stable
set search_path = public
as $$
  select case
    when extract(hour from (p at time zone 'Asia/Jakarta')) >= 21
      then (date_trunc('day', p at time zone 'Asia/Jakarta') + interval '1 day 6 hours') at time zone 'Asia/Jakarta'
    when extract(hour from (p at time zone 'Asia/Jakarta')) < 6
      then (date_trunc('day', p at time zone 'Asia/Jakarta') + interval '6 hours') at time zone 'Asia/Jakarta'
    else p
  end;
$$;

create or replace function enqueue_email(p_worker uuid, p_kind text, p_item uuid, p_actor uuid, p_payload jsonb, p_dedupe text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant uuid;
begin
  if p_worker is null or p_worker = p_actor then
    return;
  end if;
  select tenant_id into v_tenant from workers where id = p_worker and deactivated_at is null;
  if v_tenant is null then
    return;
  end if;
  insert into email_outbox (tenant_id, worker_id, kind, work_item_id, actor_id, payload, dedupe_key, not_before)
  values (v_tenant, p_worker, p_kind, p_item, p_actor, coalesce(p_payload, '{}'::jsonb), p_dedupe, email_not_before(now()))
  on conflict (dedupe_key) do nothing;
end;
$$;

-- Tugas baru atau dialihkan ke orang lain. Tugas rutin (template) tidak memicu email karena muncul setiap hari, dan perubahan tanpa
-- sesi login (migration, seed) juga tidak.
create or replace function email_on_assign()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
begin
  if v_actor is null or new.template_id is not null or new.status in ('DONE', 'CANCELLED') then
    return new;
  end if;
  if tg_op = 'INSERT' or new.owner_id is distinct from old.owner_id then
    perform enqueue_email(new.owner_id, 'ASSIGNED', new.id, v_actor,
      jsonb_build_object('due_at', new.due_at),
      'asg:' || new.id || ':' || coalesce(new.owner_id::text, '') || ':' || coalesce(new.version, 0));
  end if;
  return new;
end;
$$;

create trigger trg_email_on_assign
  after insert or update of owner_id on work_items
  for each row execute function email_on_assign();

-- Persetujuan: minta persetujuan ke manajer tim (bukan PIC-nya sendiri), keputusan ke PIC.
create or replace function email_on_approval()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  m record;
begin
  if v_actor is null or new.approval_status is not distinct from old.approval_status then
    return new;
  end if;
  if new.approval_status = 'PENDING' then
    for m in select id from workers
              where team_id = new.team_id and role = 'manager' and deactivated_at is null and id <> new.owner_id loop
      perform enqueue_email(m.id, 'APPROVAL_REQUEST', new.id, v_actor, '{}'::jsonb,
        'apr:' || new.id || ':' || coalesce(new.version, 0) || ':' || m.id);
    end loop;
  elsif new.approval_status in ('APPROVED', 'CHANGES_REQUESTED') and old.approval_status = 'PENDING' then
    perform enqueue_email(new.owner_id, 'APPROVAL_DECIDED', new.id, v_actor,
      jsonb_build_object('decision', new.approval_status),
      'apd:' || new.id || ':' || coalesce(new.version, 0));
  end if;
  return new;
end;
$$;

create trigger trg_email_on_approval
  after update of approval_status on work_items
  for each row execute function email_on_approval();

-- Mention di komentar. Isi komentar tidak ikut dikirim.
create or replace function email_on_mention()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_m uuid;
begin
  if new.mentions is null then
    return new;
  end if;
  foreach v_m in array new.mentions loop
    perform enqueue_email(v_m, 'MENTION', new.work_item_id, new.author_id, '{}'::jsonb, 'men:' || new.id || ':' || v_m);
  end loop;
  return new;
end;
$$;

create trigger trg_email_on_mention
  after insert on work_item_comments
  for each row execute function email_on_mention();

-- Ringkasan pagi (dijadwalkan 06.30 WIB): hanya untuk yang menyalakannya dan hanya kalau ada deadline hari ini atau tugas terlambat.
create or replace function enqueue_email_digests()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  r record;
  v_n integer := 0;
begin
  for r in
    select p.worker_id, w.tenant_id,
           count(*) filter (where wi.due_at < now()) as overdue,
           count(*) filter (where (wi.due_at at time zone 'Asia/Jakarta')::date = v_today and wi.due_at >= now()) as today
      from notification_prefs p
      join workers w on w.id = p.worker_id and w.deactivated_at is null
      join work_items wi on wi.owner_id = p.worker_id and wi.status not in ('DONE', 'CANCELLED')
     where p.email_digest
     group by p.worker_id, w.tenant_id
  loop
    if r.overdue + r.today > 0 then
      insert into email_outbox (tenant_id, worker_id, kind, payload, dedupe_key, not_before)
      values (r.tenant_id, r.worker_id, 'DIGEST', jsonb_build_object('overdue', r.overdue, 'today', r.today),
              'dig:' || r.worker_id || ':' || v_today, now())
      on conflict (dedupe_key) do nothing;
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end;
$$;

-- Preferensi milik sendiri.
create or replace function my_notification_prefs()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_email text;
  p notification_prefs;
  h notify_health;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  select u.email into v_email from workers w join auth.users u on u.id = w.auth_user_id where w.id = v_actor;
  select * into p from notification_prefs where worker_id = v_actor;
  select * into h from notify_health where id = 1;
  return jsonb_build_object(
    'email', v_email,
    'deliverable', v_email is not null and v_email not ilike '%.local',
    'assigned', coalesce(p.email_assigned, true),
    'mention', coalesce(p.email_mention, true),
    'approval', coalesce(p.email_approval, true),
    'digest', coalesce(p.email_digest, false),
    'lang', coalesce(p.lang, 'id'),
    'saved', p.worker_id is not null,
    'sent_30d', (select count(*) from email_outbox where worker_id = v_actor and status = 'SENT' and sent_at > now() - interval '30 days'),
    'last_sent_at', (select max(sent_at) from email_outbox where worker_id = v_actor and status = 'SENT'),
    'sender', case when h.last_run_at is null then 'unknown' else h.last_status end,
    'sender_at', h.last_run_at
  );
end;
$$;

create or replace function set_notification_prefs(p_assigned boolean, p_mention boolean, p_approval boolean, p_digest boolean, p_lang text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  if p_lang is not null and p_lang not in ('id', 'en') then
    raise exception 'invalid language';
  end if;
  insert into notification_prefs (worker_id, tenant_id, email_assigned, email_mention, email_approval, email_digest, lang, updated_at)
  values (v_actor, current_tenant_id(), coalesce(p_assigned, true), coalesce(p_mention, true), coalesce(p_approval, true),
          coalesce(p_digest, false), coalesce(p_lang, 'id'), now())
  on conflict (worker_id) do update
     set email_assigned = excluded.email_assigned, email_mention = excluded.email_mention,
         email_approval = excluded.email_approval, email_digest = excluded.email_digest,
         lang = excluded.lang, updated_at = now();
  return my_notification_prefs();
end;
$$;

-- ---- Jalur pengirim (hanya service_role, dipanggil Edge Function notify_send) ----
create or replace function notify_secret_ok(p_secret text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(p_secret, '') <> ''
     and exists (select 1 from vault.decrypted_secrets where name = 'notify_cron_secret' and decrypted_secret = p_secret);
$$;

create or replace function notify_claim(p_limit integer default 50)
returns table (id uuid, worker_id uuid, email text, full_name text, lang text, kind text, payload jsonb,
               actor_name text, title jsonb, due_at timestamptz, item_status text, workspace text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  -- Yang macet saat dikirim lebih dari 15 menit kembali ke antrean; yang tertunda 48 jam kedaluwarsa.
  update email_outbox o set status = 'PENDING' where o.status = 'SENDING' and o.not_before < now() - interval '15 minutes';
  update email_outbox o set status = 'SKIPPED', skip_reason = 'stale'
   where o.status = 'PENDING' and o.created_at < now() - interval '48 hours';

  -- Dilewati dengan alasan: penerima nonaktif, alamat tidak bisa menerima email, preferensi mati, tugas sudah selesai atau batal.
  update email_outbox o set status = 'SKIPPED', skip_reason = s.reason
    from (
      select x.id,
             case
               when w.deactivated_at is not null then 'inactive'
               when u.email is null or u.email ilike '%.local' then 'undeliverable'
               when x.kind = 'ASSIGNED' and not coalesce(p.email_assigned, true) then 'pref_off'
               when x.kind = 'MENTION' and not coalesce(p.email_mention, true) then 'pref_off'
               when x.kind in ('APPROVAL_REQUEST', 'APPROVAL_DECIDED') and not coalesce(p.email_approval, true) then 'pref_off'
               when x.kind = 'DIGEST' and not coalesce(p.email_digest, false) then 'pref_off'
               when x.kind in ('ASSIGNED', 'APPROVAL_REQUEST') and wi.status in ('DONE', 'CANCELLED') then 'item_closed'
               when x.kind = 'ASSIGNED' and wi.owner_id is distinct from x.worker_id then 'item_moved'
             end as reason
        from email_outbox x
        join workers w on w.id = x.worker_id
        left join auth.users u on u.id = w.auth_user_id
        left join notification_prefs p on p.worker_id = x.worker_id
        left join work_items wi on wi.id = x.work_item_id
       where x.status = 'PENDING' and x.not_before <= now()
    ) s
   where o.id = s.id and s.reason is not null;

  return query
  with picked as (
    select x.id from email_outbox x
     where x.status = 'PENDING' and x.not_before <= now()
     order by x.created_at
     limit greatest(1, least(coalesce(p_limit, 50), 200))
     for update skip locked
  ), upd as (
    update email_outbox x set status = 'SENDING', attempts = x.attempts + 1, not_before = now()
      from picked where x.id = picked.id
    returning x.*
  )
  select upd.id, upd.worker_id, u.email::text, w.full_name, coalesce(p.lang, 'id'), upd.kind, upd.payload,
         a.full_name, wi.title, wi.due_at, wi.status,
         case when upd.kind = 'APPROVAL_REQUEST' then 'manager' when w.role = 'manager' then 'manager' else 'employee' end,
         upd.created_at
    from upd
    join workers w on w.id = upd.worker_id
    join auth.users u on u.id = w.auth_user_id
    left join notification_prefs p on p.worker_id = upd.worker_id
    left join workers a on a.id = upd.actor_id
    left join work_items wi on wi.id = upd.work_item_id
   order by upd.worker_id, upd.created_at;
end;
$$;

create or replace function notify_mark(p_ids uuid[], p_ok boolean, p_error text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_ok then
    update email_outbox set status = 'SENT', sent_at = now(), error = null where id = any(p_ids);
  else
    update email_outbox
       set status = case when attempts >= 5 then 'FAILED' else 'PENDING' end,
           not_before = now() + make_interval(mins => 10 * attempts),
           error = left(p_error, 300)
     where id = any(p_ids);
  end if;
end;
$$;

create or replace function notify_health_set(p_status text, p_error text default null)
returns void
language sql
security definer
set search_path = public
as $$
  update notify_health set last_run_at = now(), last_status = p_status, last_error = left(p_error, 300) where id = 1;
$$;

revoke execute on function email_not_before(timestamptz) from public, anon;
revoke execute on function enqueue_email(uuid, text, uuid, uuid, jsonb, text) from public, anon, authenticated;
revoke execute on function email_on_assign() from public, anon, authenticated;
revoke execute on function email_on_approval() from public, anon, authenticated;
revoke execute on function email_on_mention() from public, anon, authenticated;
revoke execute on function enqueue_email_digests() from public, anon, authenticated;
revoke execute on function my_notification_prefs() from public, anon;
grant execute on function my_notification_prefs() to authenticated;
revoke execute on function set_notification_prefs(boolean, boolean, boolean, boolean, text) from public, anon;
grant execute on function set_notification_prefs(boolean, boolean, boolean, boolean, text) to authenticated;
revoke execute on function notify_secret_ok(text) from public, anon, authenticated;
revoke execute on function notify_claim(integer) from public, anon, authenticated;
revoke execute on function notify_mark(uuid[], boolean, text) from public, anon, authenticated;
revoke execute on function notify_health_set(text, text) from public, anon, authenticated;
grant execute on function notify_secret_ok(text) to service_role;
grant execute on function notify_claim(integer) to service_role;
grant execute on function notify_mark(uuid[], boolean, text) to service_role;
grant execute on function notify_health_set(text, text) to service_role;

-- Jadwal: pengirim tiap 5 menit (hanya memanggil fungsi kalau ada email yang jatuh tempo), ringkasan pagi 06.30 WIB.
select cron.schedule('nusva_notify_send', '*/5 * * * *', $cron$
  select net.http_post(
    url := 'https://qfvvijwieqcazmovowiq.supabase.co/functions/v1/notify_send',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-notify-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'notify_cron_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000)
  where exists (select 1 from public.email_outbox where status = 'PENDING' and not_before <= now());
$cron$);
select cron.schedule('nusva_email_digest', '30 23 * * *', $cron$ select public.enqueue_email_digests(); $cron$);
