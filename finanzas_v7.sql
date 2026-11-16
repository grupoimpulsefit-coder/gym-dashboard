-- ══════════════════════════════════════════════════════════════════════════
--  FINANZAS v7 — inventario de la casa (código de barras y fotos).
--  Correr DESPUÉS de finanzas_v6.sql. Se puede repetir sin problema.
--
--  · Solo lleva cantidades: no registra gastos ni ingresos.
--  · El grupo crea, edita y borra productos (con foto y código de barras).
--  · Un usuario de fondo (ej. Cucho) ve el inventario del grupo dueño de su
--    fondo y puede sumar o restar cantidades, pero no crear, editar ni borrar.
--  · Las cantidades cambian solo con fin_inv_mover(), que deja historial.
--  · Fotos en el bucket privado fin-inventario, carpeta = id del grupo.
-- ══════════════════════════════════════════════════════════════════════════

-- Grupo cuyo inventario puedo ver: el mío, o el del dueño de mi fondo
create or replace function public.fin_inv_grupo()
returns uuid
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select grupo from fin_duenos where user_id = auth.uid()),
    (select d.grupo from fin_fondo_usuarios fu
       join fin_fondos f on f.id = fu.fondo_id
       join fin_duenos d on d.user_id = f.owner
      where fu.user_id = auth.uid() limit 1))
$$;
revoke all on function public.fin_inv_grupo() from public, anon;
grant execute on function public.fin_inv_grupo() to authenticated;

-- ¿Soy del grupo (puedo editar productos)?
create or replace function public.fin_inv_edita()
returns boolean
language sql stable security definer set search_path = public
as $$ select exists (select 1 from fin_duenos where user_id = auth.uid()) $$;
revoke all on function public.fin_inv_edita() from public, anon;
grant execute on function public.fin_inv_edita() to authenticated;

create table if not exists fin_inventario (
  id         uuid primary key default gen_random_uuid(),
  grupo      uuid not null default public.fin_inv_grupo(),
  owner      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  nombre     text not null,
  codigo     text,                                -- código de barras (opcional)
  cantidad   numeric(12,2) not null default 0 check (cantidad >= 0),
  minimo     numeric(12,2) check (minimo >= 0),   -- avisar cuando quede esto o menos
  unidad     text,                                -- unidades, kg, paquetes…
  foto       text,                                -- ruta en el bucket fin-inventario
  nota       text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create unique index if not exists fin_inventario_codigo on fin_inventario (grupo, codigo) where codigo is not null and codigo <> '';
create index if not exists fin_inventario_grupo on fin_inventario (grupo, nombre);

create table if not exists fin_inv_movs (
  id         uuid primary key default gen_random_uuid(),
  item_id    uuid not null references fin_inventario(id) on delete cascade,
  owner      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  cambio     numeric(12,2) not null check (cambio <> 0),
  cantidad   numeric(12,2) not null,              -- cantidad que quedó
  nota       text,
  created_at timestamptz default now()
);
create index if not exists fin_inv_movs_item on fin_inv_movs (item_id, created_at desc);

alter table fin_inventario enable row level security;
alter table fin_inv_movs enable row level security;
revoke all on fin_inventario, fin_inv_movs from anon;

-- Ver: el grupo y el usuario de fondo. Crear/editar/borrar: solo el grupo, y
-- la cantidad no se toca directo (va por fin_inv_mover, ver el trigger).
drop policy if exists inv_ver on fin_inventario;
create policy inv_ver on fin_inventario for select to authenticated
  using (grupo = public.fin_inv_grupo());
drop policy if exists inv_editar on fin_inventario;
create policy inv_editar on fin_inventario for all to authenticated
  using (grupo = public.fin_inv_grupo() and public.fin_inv_edita())
  with check (grupo = public.fin_inv_grupo() and public.fin_inv_edita());

drop policy if exists inv_movs_ver on fin_inv_movs;
create policy inv_movs_ver on fin_inv_movs for select to authenticated
  using (exists (select 1 from fin_inventario i where i.id = fin_inv_movs.item_id));   -- RLS de fin_inventario filtra

-- La cantidad solo cambia por fin_inv_mover (que deja historial)
create or replace function public.fin_inv_guard()
returns trigger language plpgsql set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and new.cantidad is distinct from old.cantidad
     and coalesce(current_setting('fin.inv_mover', true), '') <> '1' then
    raise exception 'La cantidad se cambia con los botones + / − (deja historial)';
  end if;
  new.updated_at := now();
  return new;
end;
$$;
revoke all on function public.fin_inv_guard() from public, anon, authenticated;
drop trigger if exists fin_inv_guard on fin_inventario;
create trigger fin_inv_guard before update on fin_inventario
  for each row execute function public.fin_inv_guard();

-- Al crear un producto con cantidad inicial, queda en el historial
create or replace function public.fin_inv_inicial()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.cantidad > 0 then
    insert into fin_inv_movs (item_id, owner, cambio, cantidad, nota) values (new.id, new.owner, new.cantidad, new.cantidad, 'cantidad inicial');
  end if;
  return null;
end;
$$;
revoke all on function public.fin_inv_inicial() from public, anon, authenticated;
drop trigger if exists fin_inv_inicial on fin_inventario;
create trigger fin_inv_inicial after insert on fin_inventario
  for each row execute function public.fin_inv_inicial();

-- Sumar o restar: lo usan el grupo y el usuario de fondo. Devuelve la cantidad nueva.
create or replace function public.fin_inv_mover(p_item uuid, p_cambio numeric, p_nota text default null)
returns numeric
language plpgsql security definer set search_path = public
as $$
declare i fin_inventario; nueva numeric;
begin
  if p_cambio is null or p_cambio = 0 then raise exception 'Cantidad inválida'; end if;
  select * into i from fin_inventario where id = p_item for update;
  if i.id is null or i.grupo is distinct from public.fin_inv_grupo() then raise exception 'Producto no encontrado'; end if;
  nueva := i.cantidad + p_cambio;
  if nueva < 0 then raise exception 'Solo hay % de %', i.cantidad, i.nombre; end if;
  perform set_config('fin.inv_mover', '1', true);
  update fin_inventario set cantidad = nueva where id = p_item;
  perform set_config('fin.inv_mover', '', true);
  insert into fin_inv_movs (item_id, owner, cambio, cantidad, nota) values (p_item, auth.uid(), p_cambio, nueva, nullif(btrim(p_nota), ''));
  return nueva;
end;
$$;
revoke all on function public.fin_inv_mover(uuid, numeric, text) from public, anon;
grant execute on function public.fin_inv_mover(uuid, numeric, text) to authenticated;

-- Nombres de quién movió qué (grupo + usuarios de sus fondos)
create or replace function public.fin_inv_personas()
returns table (user_id uuid, nombre text)
language sql stable security definer set search_path = public
as $$
  select d.user_id, coalesce(d.nombre, '') from fin_duenos d where d.grupo = public.fin_inv_grupo()
  union
  select fu.user_id, f.nombre from fin_fondo_usuarios fu join fin_fondos f on f.id = fu.fondo_id
   join fin_duenos d on d.user_id = f.owner where d.grupo = public.fin_inv_grupo()
$$;
revoke all on function public.fin_inv_personas() from public, anon;
grant execute on function public.fin_inv_personas() to authenticated;

-- ── Fotos: bucket privado, carpeta = id del grupo ───────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fin-inventario', 'fin-inventario', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists fin_inv_fotos_ver on storage.objects;
create policy fin_inv_fotos_ver on storage.objects for select to authenticated
  using (bucket_id = 'fin-inventario' and (storage.foldername(name))[1] = public.fin_inv_grupo()::text);
drop policy if exists fin_inv_fotos_subir on storage.objects;
create policy fin_inv_fotos_subir on storage.objects for insert to authenticated
  with check (bucket_id = 'fin-inventario' and public.fin_inv_edita() and (storage.foldername(name))[1] = public.fin_inv_grupo()::text);
drop policy if exists fin_inv_fotos_cambiar on storage.objects;
create policy fin_inv_fotos_cambiar on storage.objects for update to authenticated
  using (bucket_id = 'fin-inventario' and public.fin_inv_edita() and (storage.foldername(name))[1] = public.fin_inv_grupo()::text);
drop policy if exists fin_inv_fotos_borrar on storage.objects;
create policy fin_inv_fotos_borrar on storage.objects for delete to authenticated
  using (bucket_id = 'fin-inventario' and public.fin_inv_edita() and (storage.foldername(name))[1] = public.fin_inv_grupo()::text);
