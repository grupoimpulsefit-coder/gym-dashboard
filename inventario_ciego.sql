-- ══════════════════════════════════════════════════════════════════════════
--  INVENTARIO A CIEGAS PARA RECEPCIÓN (también en la base, no solo en pantalla)
--  Correr UNA vez en Supabase → SQL Editor, después de inventario_proteccion.sql
--  y facturacion.sql. Se puede repetir sin problema.
--
--  Antes, caja escondía la cantidad en pantalla, pero el navegador la recibía
--  igual (y recepción podía leer la tabla inventario y el "sistema" guardado en
--  cada conteo), así que con las herramientas del navegador se podía ver.
--  Ahora:
--    · recepción NO lee la tabla inventario: caja usa inventario_caja(), que le
--      da productos y precios SIN la cantidad (solo si está agotado);
--    · el conteo de apertura/cierre se compara EN LA BASE con
--      registrar_conteo(): el cierre guarda {contado, difiere} y lo que tenía el
--      sistema va a cierres_inventario, que solo ven quienes ven el stock;
--    · ven el stock real: administradores, coordinador y admin de sucursal.
--  Vender más de lo que hay ya lo impide facturar_caja() (facturacion.sql).
-- ══════════════════════════════════════════════════════════════════════════

-- ── ¿Quién trabaja la caja de una sede? ¿Quién ve el stock real? ───────────
create or replace function public.es_de_caja(p_sede text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from user_roles ur where ur.id = auth.uid() and (
    ur.role in ('admin','admin_sedes','admin_g')
    or (ur.role in ('recepcion','admin_sucursal','coordinador')
        and (ur.sede = p_sede or p_sede = any(coalesce(ur.sedes_extra, '{}'))))))
$$;

create or replace function public.ve_stock(p_sede text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from user_roles ur where ur.id = auth.uid() and (
    ur.role in ('admin','admin_sedes','admin_g')
    or (ur.role = 'coordinador' and (ur.sede is null or ur.sede = p_sede or p_sede = any(coalesce(ur.sedes_extra, '{}'))))
    or (ur.role = 'admin_sucursal' and (ur.sede = p_sede or p_sede = any(coalesce(ur.sedes_extra, '{}'))))))
$$;

-- ── Recepción ya no lee ni modifica la tabla inventario directamente ───────
-- (facturar, aceptar envíos y contar pasan por funciones de la base)
drop policy if exists inventario_recep_select on inventario;
create policy inventario_recep_select on inventario
  for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin_sucursal','coordinador')
          and (ur.sede = inventario.sede or inventario.sede = any(ur.sedes_extra))));

drop policy if exists inventario_recep_update on inventario;
create policy inventario_recep_update on inventario
  for update to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin_sucursal','coordinador')
          and (ur.sede = inventario.sede or inventario.sede = any(ur.sedes_extra))))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin_sucursal','coordinador')
          and (ur.sede = inventario.sede or inventario.sede = any(ur.sedes_extra))));

-- ── Lista de productos para caja: la cantidad solo a quien ve el stock ─────
create or replace function public.inventario_caja(p_sede text)
returns table (id uuid, producto text, precio numeric, cantidad_minima numeric, activo boolean, agotado boolean, cantidad numeric)
language plpgsql stable security definer set search_path = public as $$
declare v_ve boolean := public.ve_stock(p_sede);
begin
  if not public.es_de_caja(p_sede) then
    raise exception 'No tiene acceso al inventario de %.', p_sede using errcode = '42501';
  end if;
  return query
    select i.id, i.producto::text, i.precio::numeric, i.cantidad_minima::numeric, coalesce(i.activo, true),
           coalesce(i.cantidad, 0) <= 0,
           case when v_ve then i.cantidad::numeric else null end
      from inventario i
     where i.sede = p_sede
     order by i.producto;
end;
$$;
revoke all on function public.inventario_caja(text) from public;
grant execute on function public.inventario_caja(text) to authenticated;

-- ── Lo que tenía el sistema en cada conteo (aparte: recepción no lo lee) ───
create table if not exists cierres_inventario (
  cierre_id  uuid not null references cierres_caja(id) on delete cascade,
  tipo       text not null check (tipo in ('apertura','cierre')),
  sistema    jsonb not null,                   -- { producto: cantidad en el sistema }
  updated_at timestamptz default now(),
  primary key (cierre_id, tipo)
);
alter table cierres_inventario enable row level security;
drop policy if exists cierres_inv_select on cierres_inventario;
create policy cierres_inv_select on cierres_inventario
  for select to authenticated
  using (exists (select 1 from cierres_caja c where c.id = cierres_inventario.cierre_id and public.ve_stock(c.sede)));
-- Sin políticas de escritura: solo registrar_conteo() (security definer) escribe aquí.

-- ── Registrar un conteo: la base compara con el sistema ────────────────────
-- p_contados: { producto: cantidad contada | null }
-- Devuelve { conteo: {producto: {contado, difiere}}, sistema: {producto: n} o null según el rol }
create or replace function public.registrar_conteo(p_cierre uuid, p_tipo text, p_contados jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_c     cierres_caja%rowtype;
  v_blind jsonb := '{}'::jsonb;
  v_sis   jsonb := '{}'::jsonb;
  v_cont  numeric;
  r       record;
begin
  if p_tipo not in ('apertura','cierre') then raise exception 'Tipo de conteo inválido.'; end if;
  select * into v_c from cierres_caja where id = p_cierre for update;
  if not found then raise exception 'El turno no existe.'; end if;
  if not public.es_de_caja(v_c.sede) then
    raise exception 'No tiene acceso a la caja de %.', v_c.sede using errcode = '42501';
  end if;
  if coalesce(v_c.estado, 'abierto') <> 'abierto' and not public.ve_stock(v_c.sede) then
    raise exception 'El turno ya está cerrado: el conteo no se puede cambiar.' using errcode = '42501';
  end if;

  for r in select producto, coalesce(cantidad, 0)::numeric as cant from inventario where sede = v_c.sede loop
    if p_contados ? r.producto then
      v_cont := nullif(p_contados ->> r.producto, '')::numeric;
      v_blind := v_blind || jsonb_build_object(r.producto,
                   jsonb_build_object('contado', v_cont, 'difiere', v_cont is not null and v_cont <> r.cant));
      v_sis := v_sis || jsonb_build_object(r.producto, r.cant);
    end if;
  end loop;

  if p_tipo = 'apertura' then
    update cierres_caja set inventario_apertura = v_blind, updated_at = now() where id = p_cierre;
  else
    update cierres_caja set inventario_cierre = v_blind, updated_at = now() where id = p_cierre;
  end if;
  insert into cierres_inventario (cierre_id, tipo, sistema, updated_at)
  values (p_cierre, p_tipo, v_sis, now())
  on conflict (cierre_id, tipo) do update set sistema = excluded.sistema, updated_at = now();

  return jsonb_build_object('conteo', v_blind,
                            'sistema', case when public.ve_stock(v_c.sede) then v_sis else null end);
end;
$$;
revoke all on function public.registrar_conteo(uuid, text, jsonb) from public;
grant execute on function public.registrar_conteo(uuid, text, jsonb) to authenticated;

-- ── Conteos ya guardados: pasar el "sistema" a la tabla aparte ─────────────
insert into cierres_inventario (cierre_id, tipo, sistema)
select c.id, 'apertura',
       (select jsonb_object_agg(e.k, coalesce((e.v ->> 'sistema')::numeric, 0))
          from jsonb_each(c.inventario_apertura::jsonb) e(k, v) where jsonb_typeof(e.v) = 'object')
  from cierres_caja c
 where jsonb_typeof(c.inventario_apertura::jsonb) = 'object'
   and exists (select 1 from jsonb_each(c.inventario_apertura::jsonb) e(k, v) where jsonb_typeof(e.v) = 'object' and e.v ? 'sistema')
on conflict do nothing;

insert into cierres_inventario (cierre_id, tipo, sistema)
select c.id, 'cierre',
       (select jsonb_object_agg(e.k, coalesce((e.v ->> 'sistema')::numeric, 0))
          from jsonb_each(c.inventario_cierre::jsonb) e(k, v) where jsonb_typeof(e.v) = 'object')
  from cierres_caja c
 where jsonb_typeof(c.inventario_cierre::jsonb) = 'object'
   and exists (select 1 from jsonb_each(c.inventario_cierre::jsonb) e(k, v) where jsonb_typeof(e.v) = 'object' and e.v ? 'sistema')
on conflict do nothing;

-- …y dejar en el cierre solo {contado, difiere}
update cierres_caja c
   set inventario_apertura = (
     select coalesce(jsonb_object_agg(e.k, jsonb_build_object(
              'contado', e.v -> 'contado',
              'difiere', (e.v ->> 'contado') is not null and (e.v ->> 'sistema') is not null
                         and (e.v ->> 'contado')::numeric <> (e.v ->> 'sistema')::numeric)), '{}'::jsonb)
       from jsonb_each(c.inventario_apertura::jsonb) e(k, v) where jsonb_typeof(e.v) = 'object')
 where jsonb_typeof(c.inventario_apertura::jsonb) = 'object'
   and exists (select 1 from jsonb_each(c.inventario_apertura::jsonb) e(k, v) where jsonb_typeof(e.v) = 'object' and e.v ? 'sistema');

update cierres_caja c
   set inventario_cierre = (
     select coalesce(jsonb_object_agg(e.k, jsonb_build_object(
              'contado', e.v -> 'contado',
              'difiere', (e.v ->> 'contado') is not null and (e.v ->> 'sistema') is not null
                         and (e.v ->> 'contado')::numeric <> (e.v ->> 'sistema')::numeric)), '{}'::jsonb)
       from jsonb_each(c.inventario_cierre::jsonb) e(k, v) where jsonb_typeof(e.v) = 'object')
 where jsonb_typeof(c.inventario_cierre::jsonb) = 'object'
   and exists (select 1 from jsonb_each(c.inventario_cierre::jsonb) e(k, v) where jsonb_typeof(e.v) = 'object' and e.v ? 'sistema');

-- Comprobación: conteos movidos y cierres que todavía guardan "sistema" (debe dar 0)
select 'conteos con sistema aparte' as que, count(*)::text as valor from cierres_inventario
union all
select 'cierres con sistema a la vista', count(*)::text from cierres_caja c
 where exists (select 1 from jsonb_each(coalesce(c.inventario_apertura::jsonb, '{}'::jsonb)) e(k, v) where jsonb_typeof(e.v) = 'object' and e.v ? 'sistema')
    or exists (select 1 from jsonb_each(coalesce(c.inventario_cierre::jsonb, '{}'::jsonb)) e(k, v) where jsonb_typeof(e.v) = 'object' and e.v ? 'sistema');
