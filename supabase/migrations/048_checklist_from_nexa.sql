-- 048: menambah langkah checklist ke tugas yang sudah ada, termasuk dari saran Nexa.
--
-- Sampai sekarang checklist hanya lahir dari template tugas rutin; tugas biasa tidak punya jalur untuk menambah langkah.
-- Saran Nexa di detail tugas (Edge Function task_suggest, tingkat N2: draf) mengusulkan langkah dari nama tugas, dan
-- orang yang berhak mengubah tugas itu memilih langkah mana yang dipakai. Migration ini:
-- 1. checklist_items.ai_assisted: penanda jujur bahwa langkah itu berasal dari saran Nexa yang dipilih manusia. Diisi saat
--    langkah dibuat dan tidak bisa diubah sesudahnya (trigger guard_checklist_ai).
-- 2. RPC add_checklist_items(p_work_item_id, p_items, p_ai): hak sama dengan mengubah tugas (can_manage_work_item: PIC, manajer
--    tim tugas itu, eksekutif, HC). Ditolak untuk tugas selesai, dibatalkan, menunggu persetujuan, dan tugas rutin (checklist
--    rutin datang dari template). Langkah kosong diabaikan, paling sedikit 1 dan paling banyak 12 per panggilan, 120 karakter
--    per langkah, dan paling banyak 20 langkah per tugas. Langkah baru ditaruh di akhir dan belum dicentang. Judul checklist
--    berbentuk jsonb {id, en}; langkah baru ditulis dalam satu bahasa (bahasa layar saat ditambahkan), jadi teks yang sama
--    diisi ke kedua kunci.
-- 3. Tidak ada DROP, REVOKE ALL, atau DELETE. Perubahan tercatat lewat trigger audit yang sudah ada.

alter table checklist_items add column if not exists ai_assisted boolean not null default false;

create or replace function guard_checklist_ai()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.ai_assisted is distinct from old.ai_assisted then
    raise exception 'ai_assisted cannot be changed';
  end if;
  return new;
end;
$$;

create trigger trg_guard_checklist_ai
  before update on checklist_items
  for each row execute function guard_checklist_ai();

create or replace function add_checklist_items(p_work_item_id uuid, p_items text[], p_ai boolean default false)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := current_worker_id();
  v_tenant uuid := current_tenant_id();
  v_item work_items;
  v_items text[];
  v_have integer;
  v_pos integer;
  v_t text;
begin
  if v_actor is null then
    raise exception 'not authenticated';
  end if;
  select * into v_item from work_items where id = p_work_item_id and tenant_id = v_tenant for update;
  if not found or v_item.status = 'CANCELLED' then
    raise exception 'work item not found';
  end if;
  if not can_manage_work_item(v_item.owner_id, v_item.team_id) then
    raise exception 'not authorized to change this work item';
  end if;
  if v_item.status = 'DONE' then
    raise exception 'cannot edit a finished work item';
  end if;
  if v_item.approval_status = 'PENDING' then
    raise exception 'cannot edit while waiting for approval';
  end if;
  if v_item.template_id is not null then
    raise exception 'routine checklist comes from its template';
  end if;

  select coalesce(array_agg(t order by ord), '{}') into v_items
    from (select btrim(regexp_replace(x, '\s+', ' ', 'g')) as t, ord
            from unnest(coalesce(p_items, '{}')) with ordinality as u(x, ord)) s
   where t <> '';
  if cardinality(v_items) = 0 then
    raise exception 'checklist item is required';
  end if;
  if cardinality(v_items) > 12 then
    raise exception 'too many checklist items';
  end if;
  foreach v_t in array v_items loop
    if char_length(v_t) > 120 then
      raise exception 'text is too long';
    end if;
  end loop;
  select count(*), coalesce(max(position), 0) into v_have, v_pos from checklist_items where work_item_id = v_item.id;
  if v_have + cardinality(v_items) > 20 then
    raise exception 'too many checklist items';
  end if;

  insert into checklist_items (tenant_id, work_item_id, title, done, position, ai_assisted)
  select v_tenant, v_item.id, jsonb_build_object('id', t, 'en', t), false, v_pos + ord, coalesce(p_ai, false)
    from unnest(v_items) with ordinality as u(t, ord);
  return cardinality(v_items);
end;
$$;

revoke execute on function add_checklist_items(uuid, text[], boolean) from public;
revoke execute on function add_checklist_items(uuid, text[], boolean) from anon;
grant execute on function add_checklist_items(uuid, text[], boolean) to authenticated;
