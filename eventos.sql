-- ══════════════════════════════════════════════════════════════════════════
--  CAJA — Eventos de un día (ej. baile) cobrados desde caja.html
--  Correr en el SQL editor de Supabase DESPUÉS de facturacion.sql.
--  Se puede repetir sin problema.
--
--  Un administrador crea el evento con dos precios (miembro / no miembro),
--  las sedes donde se vende y los métodos de pago que acepta. Recepción cobra
--  una persona por cobro:
--    • miembro    → con su PIN; la base verifica que sea cliente ACTIVO en la
--                   lista de clientes más reciente de cualquiera de las sedes
--                   (gym_snapshots.users_data, la que se sube en el dashboard).
--    • no miembro → nombre y teléfono.
--  El cobro se guarda en facturas_caja (tipo 'evento'): entra al cierre de la
--  sede en Tarjeta / SINPE / Total ventas, pero no al sobre de la minita.
--  No toca el inventario. Se anula con anular_factura_caja() como las demás.
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists eventos_caja (
  id                 uuid primary key default gen_random_uuid(),
  nombre             text not null,
  fecha              date not null,                 -- día del evento; se vende hasta ese día
  precio_miembro     numeric not null check (precio_miembro >= 0),
  precio_no_miembro  numeric not null check (precio_no_miembro >= 0),
  metodos            text[] not null default array['efectivo','tarjeta','sinpe'],
  sedes              text[] not null,
  activo             boolean not null default true,
  created_by         text,
  created_at         timestamptz default now(),
  updated_at         timestamptz default now(),
  constraint eventos_metodos_ok check (cardinality(metodos) > 0 and metodos <@ array['efectivo','tarjeta','sinpe']),
  constraint eventos_sedes_ok   check (cardinality(sedes) > 0)
);
create index if not exists eventos_caja_fecha_idx on eventos_caja (fecha desc);

alter table eventos_caja enable row level security;
drop policy if exists eventos_select on eventos_caja;
create policy eventos_select on eventos_caja
  for select to authenticated
  using (public.mi_rol() in ('admin','admin_sedes','admin_g','recepcion','admin_sucursal','coordinador'));
drop policy if exists eventos_admin on eventos_caja;
create policy eventos_admin on eventos_caja
  for all to authenticated
  using      (public.mi_rol() in ('admin','admin_sedes','admin_g'))
  with check (public.mi_rol() in ('admin','admin_sedes','admin_g'));

-- ── Cobros de eventos en facturas_caja ────────────────────────────────────
alter table facturas_caja add column if not exists tipo text not null default 'producto';
alter table facturas_caja drop constraint if exists facturas_caja_tipo_ok;
alter table facturas_caja add constraint facturas_caja_tipo_ok check (tipo in ('producto','evento'));
alter table facturas_caja add column if not exists evento_id        uuid references eventos_caja(id);
alter table facturas_caja add column if not exists tipo_precio      text;   -- 'miembro' | 'no_miembro'
alter table facturas_caja add column if not exists cliente_nombre   text;
alter table facturas_caja add column if not exists cliente_telefono text;
alter table facturas_caja add column if not exists cliente_pin      text;
create index if not exists facturas_caja_evento_idx on facturas_caja (evento_id);

-- ── Buscar un cliente por PIN en la lista más reciente de cada sede ───────
-- Devuelve { pin, nombre, telefono, activo, sede } o null si no existe.
-- Prefiere el registro activo; si no hay, devuelve el más reciente encontrado.
create or replace function buscar_cliente_pin(p_pin text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_pin text := btrim(coalesce(p_pin, ''));
  v_res jsonb;
begin
  if public.mi_rol() not in ('admin','admin_sedes','admin_g','recepcion','admin_sucursal','coordinador') then
    raise exception 'Sin permiso.' using errcode = '42501';
  end if;
  if v_pin = '' then return null; end if;

  with ult as (
    select distinct on (sede) sede, users_data::jsonb as ud
      from gym_snapshots
     where case when jsonb_typeof(users_data::jsonb) = 'array'
                then jsonb_array_length(users_data::jsonb) else 0 end > 0   -- hay cargas solo de ventas con la lista vacía
     order by sede, updated_at desc
  )
  select jsonb_build_object('pin', u ->> 'PIN', 'nombre', u ->> 'Nombre', 'telefono', u ->> 'Telefono',
                            'activo', lower(coalesce(u ->> 'Activo', '')) in ('sí','si'), 'sede', ult.sede)
    into v_res
    from ult, jsonb_array_elements(ult.ud) u
   where btrim(u ->> 'PIN') = v_pin
   order by (lower(coalesce(u ->> 'Activo', '')) in ('sí','si')) desc
   limit 1;

  return v_res;
end;
$$;
revoke all on function buscar_cliente_pin(text) from public;
grant execute on function buscar_cliente_pin(text) to authenticated;

-- ── Cobrar un evento (una persona por cobro) ──────────────────────────────
create or replace function vender_evento_caja(p_cierre uuid, p_evento uuid, p_tipo_precio text, p_metodo text,
                                              p_nombre text default null, p_telefono text default null,
                                              p_pin text default null, p_recibido numeric default null,
                                              p_referencia text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_rol    text := public.mi_rol();
  v_email  text := auth.jwt() ->> 'email';
  v_c      cierres_caja%rowtype;
  v_e      eventos_caja%rowtype;
  v_cli    jsonb;
  v_nombre text := nullif(btrim(coalesce(p_nombre, '')), '');
  v_tel    text := nullif(regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g'), '');
  v_pin    text := nullif(btrim(coalesce(p_pin, '')), '');
  v_ref    text := nullif(btrim(coalesce(p_referencia, '')), '');
  v_precio numeric;
  v_num    int;
  v_id     uuid;
begin
  select * into v_c from cierres_caja where id = p_cierre for update;   -- serializa los cobros del turno
  if not found then raise exception 'El turno no existe.'; end if;
  if v_c.estado <> 'abierto' then raise exception 'El turno ya está cerrado. Abra un turno para cobrar.'; end if;
  if not (v_rol in ('admin','admin_sedes','admin_g') or exists (
      select 1 from user_roles ur where ur.id = auth.uid()
        and ur.role in ('recepcion','admin_sucursal','coordinador')
        and (ur.sede = v_c.sede or v_c.sede = any(ur.sedes_extra)))) then
    raise exception 'No puede cobrar en esta sede.' using errcode = '42501';
  end if;

  select * into v_e from eventos_caja where id = p_evento;
  if not found then raise exception 'El evento no existe.'; end if;
  if not v_e.activo then raise exception 'El evento % ya no está a la venta.', v_e.nombre; end if;
  if not (v_c.sede = any(v_e.sedes)) then raise exception 'El evento % no se vende en %.', v_e.nombre, v_c.sede; end if;
  if v_e.fecha < (now() at time zone 'America/Costa_Rica')::date then
    raise exception 'El evento % ya pasó.', v_e.nombre;
  end if;
  if not (p_metodo = any(v_e.metodos)) then
    raise exception 'Este evento no acepta pago con %.', p_metodo;
  end if;
  if p_metodo = 'sinpe' and (v_ref is null or length(regexp_replace(v_ref, '\D', '', 'g')) < 4) then
    raise exception 'Anote la referencia del SINPE (al menos los últimos 4 dígitos).';
  end if;

  if p_tipo_precio = 'miembro' then
    if v_pin is null then raise exception 'Anote el PIN del cliente para el precio de miembro.'; end if;
    v_cli := buscar_cliente_pin(v_pin);
    if v_cli is null then raise exception 'El PIN % no aparece en la lista de clientes. Cobre como no miembro.', v_pin; end if;
    if not (v_cli ->> 'activo')::boolean then
      raise exception 'El cliente con PIN % no está activo. Cobre como no miembro.', v_pin;
    end if;
    v_nombre := coalesce(v_cli ->> 'nombre', v_nombre);
    v_tel    := coalesce(v_tel, nullif(regexp_replace(coalesce(v_cli ->> 'telefono', ''), '\D', '', 'g'), ''));
    v_precio := v_e.precio_miembro;
  elsif p_tipo_precio = 'no_miembro' then
    if v_nombre is null then raise exception 'Anote el nombre de la persona.'; end if;
    if v_tel is null or length(v_tel) < 8 then raise exception 'Anote un teléfono de 8 dígitos.'; end if;
    v_pin    := null;
    v_precio := v_e.precio_no_miembro;
  else
    raise exception 'Tipo de precio inválido.';
  end if;

  if p_metodo = 'efectivo' and p_recibido is not null and p_recibido < v_precio then
    raise exception 'El efectivo recibido (₡%) no cubre el total (₡%).', p_recibido, v_precio;
  end if;

  select coalesce(max(numero), 0) + 1 into v_num from facturas_caja where sede = v_c.sede and fecha = v_c.fecha;

  insert into facturas_caja (sede, fecha, numero, cierre_id, metodo, items, total, recibido, referencia, created_by,
                             tipo, evento_id, tipo_precio, cliente_nombre, cliente_telefono, cliente_pin)
  values (v_c.sede, v_c.fecha, v_num, v_c.id, p_metodo,
          jsonb_build_array(jsonb_build_object('evento_id', v_e.id, 'producto', v_e.nombre, 'cantidad', 1,
                                               'precio', v_precio, 'total', v_precio)),
          v_precio, case when p_metodo = 'efectivo' then p_recibido end,
          case when p_metodo = 'sinpe' then v_ref end, v_email,
          'evento', v_e.id, p_tipo_precio, v_nombre, v_tel, v_pin)
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'numero', v_num, 'total', v_precio, 'nombre', v_nombre);
end;
$$;
revoke all on function vender_evento_caja(uuid, uuid, text, text, text, text, text, numeric, text) from public;
grant execute on function vender_evento_caja(uuid, uuid, text, text, text, text, text, numeric, text) to authenticated;
