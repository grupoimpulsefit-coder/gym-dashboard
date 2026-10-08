-- ══════════════════════════════════════════════════════════════════════════
--  CAJA — Facturación de productos (minita y otros) desde caja.html
--  Correr en el SQL editor de Supabase DESPUÉS de inventario_proteccion.sql
--  (vuelva a correr ese archivo también: inventario_guard ahora reconoce las
--  facturas para el detalle del kardex). Se puede repetir sin problema.
--
--  Cada factura queda ligada al turno abierto, guarda el método de pago y
--  descuenta el inventario en la MISMA transacción. Precio y stock salen de la
--  base, no del navegador. Desde la página no se puede insertar ni editar la
--  tabla directo: solo con facturar_caja() y anular_factura_caja().
--
--  Pago dividido: facturar_caja_v2() recibe la lista de pagos, por ejemplo
--  [ {metodo:'sinpe', monto:1000, referencia:'123456'}, {metodo:'efectivo', monto:100} ],
--  y la base valida que sumen exactamente el total. facturar_caja() (un solo
--  método) queda como atajo de facturar_caja_v2().
--
--  Para el inventario se usa el mismo control diario que ya valida
--  inventario_guard (desc_dia / desc_hoy): cantidad baja y desc_hoy sube en
--  las mismas unidades.
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists facturas_caja (
  id                uuid primary key default gen_random_uuid(),
  sede              text not null,
  fecha             date not null,              -- día del cierre (el del turno)
  numero            int  not null,              -- consecutivo por sede y día
  cierre_id         uuid not null references cierres_caja(id),
  metodo            text not null check (metodo in ('efectivo','tarjeta','sinpe')),
  items             jsonb not null,             -- [ { inventario_id, producto, cantidad, precio, total, desc_dia } ]
  total             numeric not null,
  recibido          numeric,                    -- efectivo: monto entregado por el cliente
  referencia        text,                       -- sinpe: referencia de la transferencia
  estado            text not null default 'activa' check (estado in ('activa','anulada')),
  motivo_anulacion  text,
  anulada_por       text,
  anulada_at        timestamptz,
  created_by        text,
  created_at        timestamptz default now()
);
-- Pago dividido: metodo = 'mixto' y el detalle en pagos
alter table facturas_caja drop constraint if exists facturas_caja_metodo_check;
alter table facturas_caja add constraint facturas_caja_metodo_check check (metodo in ('efectivo','tarjeta','sinpe','mixto'));
alter table facturas_caja add column if not exists pagos jsonb;   -- [ { metodo, monto, referencia } ]
create unique index if not exists facturas_caja_num_idx   on facturas_caja (sede, fecha, numero);
create index        if not exists facturas_caja_cierre_idx on facturas_caja (cierre_id);

-- Totales facturados que el cierre suma a cada método (instantánea al guardar):
-- { efectivo, tarjeta, sinpe, total, n, desglose: { normProd: { base, qty, total } } }
alter table cierres_caja add column if not exists facturado jsonb;

-- ── RLS: solo lectura para el personal de la sede y administradores ────────
alter table facturas_caja enable row level security;
drop policy if exists facturas_caja_select on facturas_caja;
create policy facturas_caja_select on facturas_caja
  for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
          and (ur.role in ('admin','admin_sedes','admin_g')
               or (ur.role in ('recepcion','admin_sucursal','coordinador')
                   and (ur.sede = facturas_caja.sede or facturas_caja.sede = any(ur.sedes_extra))))));

-- ── Facturar: registra la factura y descuenta el stock en un solo paso ─────
-- p_items: [ { inventario_id, cantidad } ]. Lo demás (nombre, precio) sale de la base.
-- p_pagos: [ { metodo, monto, referencia } ], un método a lo sumo una vez. Con un solo
-- pago, monto puede ir vacío (= el total). p_recibido: efectivo entregado (para el vuelto).
create or replace function facturar_caja_v2(p_cierre uuid, p_items jsonb, p_pagos jsonb,
                                            p_recibido numeric default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_rol    text := public.mi_rol();
  v_email  text := auth.jwt() ->> 'email';
  v_hoy    date := (now() at time zone 'America/Costa_Rica')::date;
  v_c      cierres_caja%rowtype;
  v_it     jsonb;
  v_inv    inventario%rowtype;
  v_qty    numeric;
  v_items  jsonb := '[]'::jsonb;
  v_total  numeric := 0;
  v_num    int;
  v_ref    text;
  v_id     uuid;
  v_motivo text;
  v_p      jsonb;
  v_pagos  jsonb := '[]'::jsonb;
  v_suma   numeric := 0;
  v_ef     numeric := 0;
  v_mets   text[] := '{}';
  v_monto  numeric;
begin
  select * into v_c from cierres_caja where id = p_cierre for update;   -- serializa las facturas del turno
  if not found then raise exception 'El turno no existe.'; end if;
  if v_c.estado <> 'abierto' then raise exception 'El turno ya está cerrado. Abra un turno para facturar.'; end if;

  if not (v_rol in ('admin','admin_sedes','admin_g') or exists (
      select 1 from user_roles ur where ur.id = auth.uid()
        and ur.role in ('recepcion','admin_sucursal','coordinador')
        and (ur.sede = v_c.sede or v_c.sede = any(ur.sedes_extra)))) then
    raise exception 'No puede facturar en esta sede.' using errcode = '42501';
  end if;

  if jsonb_typeof(p_pagos) is distinct from 'array' or jsonb_array_length(p_pagos) = 0 then
    raise exception 'Indique cómo se pagó.';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'La factura no tiene productos.';
  end if;

  select coalesce(max(numero), 0) + 1 into v_num from facturas_caja where sede = v_c.sede and fecha = v_c.fecha;
  v_motivo := 'venta: factura #' || v_num || ' de caja';
  perform set_config('app.factura_caja', v_motivo, true);   -- detalle del kardex (inventario_guard)

  for v_it in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_it ->> 'cantidad')::numeric;
    if v_qty is null or v_qty <= 0 or v_qty <> trunc(v_qty) then
      raise exception 'Cantidad inválida.';
    end if;
    select * into v_inv from inventario
     where id = (v_it ->> 'inventario_id')::uuid and sede = v_c.sede for update;
    if not found then raise exception 'Un producto no existe en el inventario de %.', v_c.sede; end if;
    if v_inv.activo is false then raise exception '% está inactivo.', v_inv.producto; end if;
    if coalesce(v_inv.precio, 0) <= 0 then
      raise exception '% no tiene precio. Pídale a un administrador que lo ponga en Inventario.', v_inv.producto;
    end if;
    if coalesce(v_inv.cantidad, 0) < v_qty then
      raise exception 'No hay suficiente % en el inventario del sistema.', v_inv.producto;   -- sin la cantidad: recepción cuenta a ciegas
    end if;

    update inventario
       set cantidad   = coalesce(cantidad, 0) - v_qty,
           desc_hoy   = case when desc_dia = v_hoy then coalesce(desc_hoy, 0) else 0 end + v_qty,
           desc_dia   = v_hoy,
           updated_at = now(),
           mov_motivo = v_motivo
     where id = v_inv.id;

    v_items := v_items || jsonb_build_object('inventario_id', v_inv.id, 'producto', v_inv.producto,
                 'cantidad', v_qty, 'precio', v_inv.precio, 'total', v_inv.precio * v_qty, 'desc_dia', v_hoy);
    v_total := v_total + v_inv.precio * v_qty;
  end loop;

  perform set_config('app.factura_caja', '', true);

  -- Pagos: métodos válidos y sin repetir, montos positivos que suman el total
  for v_p in select * from jsonb_array_elements(p_pagos) loop
    if (v_p ->> 'metodo') is null or (v_p ->> 'metodo') not in ('efectivo','tarjeta','sinpe') then
      raise exception 'Método de pago inválido.';
    end if;
    if (v_p ->> 'metodo') = any(v_mets) then raise exception 'Cada método de pago va una sola vez.'; end if;
    v_mets  := v_mets || (v_p ->> 'metodo');
    v_monto := case when jsonb_array_length(p_pagos) = 1 and nullif(v_p ->> 'monto', '') is null
                    then v_total else (v_p ->> 'monto')::numeric end;
    if v_monto is null or v_monto <= 0 then raise exception 'Cada pago debe tener un monto mayor a cero.'; end if;
    if (v_p ->> 'metodo') = 'sinpe' then
      v_ref := nullif(btrim(coalesce(v_p ->> 'referencia', '')), '');
      if v_ref is null or length(regexp_replace(v_ref, '\D', '', 'g')) < 4 then
        raise exception 'Anote la referencia del SINPE (al menos los últimos 4 dígitos).';
      end if;
    end if;
    if (v_p ->> 'metodo') = 'efectivo' then v_ef := v_monto; end if;
    v_suma  := v_suma + v_monto;
    v_pagos := v_pagos || jsonb_build_object('metodo', v_p ->> 'metodo', 'monto', v_monto,
                                             'referencia', case when (v_p ->> 'metodo') = 'sinpe' then v_ref end);
  end loop;
  if v_suma <> v_total then
    raise exception 'Los pagos suman ₡% y el total es ₡%.', v_suma, v_total;
  end if;
  if v_ef > 0 and p_recibido is not null and p_recibido < v_ef then
    raise exception 'El efectivo recibido (₡%) no cubre la parte en efectivo (₡%).', p_recibido, v_ef;
  end if;

  insert into facturas_caja (sede, fecha, numero, cierre_id, metodo, pagos, items, total, recibido, referencia, created_by)
  values (v_c.sede, v_c.fecha, v_num, v_c.id,
          case when jsonb_array_length(v_pagos) = 1 then v_pagos -> 0 ->> 'metodo' else 'mixto' end,
          v_pagos, v_items, v_total,
          case when v_ef > 0 then p_recibido end, v_ref, v_email)
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'numero', v_num, 'total', v_total);
end;
$$;
revoke all on function facturar_caja_v2(uuid, jsonb, jsonb, numeric) from public;
grant execute on function facturar_caja_v2(uuid, jsonb, jsonb, numeric) to authenticated;

-- Un solo método de pago (lo que usaba la página antes del pago dividido)
create or replace function facturar_caja(p_cierre uuid, p_metodo text, p_items jsonb,
                                         p_recibido numeric default null, p_referencia text default null)
returns jsonb language sql security definer set search_path = public as $$
  select facturar_caja_v2(p_cierre, p_items,
                          jsonb_build_array(jsonb_build_object('metodo', p_metodo, 'referencia', p_referencia)),
                          p_recibido)
$$;
revoke all on function facturar_caja(uuid, text, jsonb, numeric, text) from public;
grant execute on function facturar_caja(uuid, text, jsonb, numeric, text) to authenticated;

-- ── Anular: devuelve el stock. Solo coordinador o administradores, y solo
--    mientras el turno de la factura siga abierto (un cierre ya guardado no cambia).
create or replace function anular_factura_caja(p_factura uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_rol   text := public.mi_rol();
  v_email text := auth.jwt() ->> 'email';
  v_admin boolean := v_rol in ('admin','admin_sedes','admin_g');
  v_f     facturas_caja%rowtype;
  v_c     cierres_caja%rowtype;
  v_it    jsonb;
  v_inv   inventario%rowtype;
  v_qty   numeric;
  v_motivo text;
begin
  select * into v_f from facturas_caja where id = p_factura for update;
  if not found then raise exception 'La factura no existe.'; end if;
  if v_f.estado = 'anulada' then raise exception 'La factura ya estaba anulada.'; end if;
  if nullif(btrim(coalesce(p_motivo, '')), '') is null then raise exception 'Indique el motivo de la anulación.'; end if;

  if not (v_admin or exists (
      select 1 from user_roles ur where ur.id = auth.uid() and ur.role = 'coordinador'
        and (ur.sede = v_f.sede or v_f.sede = any(ur.sedes_extra)))) then
    raise exception 'Solo un coordinador o un administrador puede anular facturas.' using errcode = '42501';
  end if;

  select * into v_c from cierres_caja where id = v_f.cierre_id for update;
  if not found or v_c.estado <> 'abierto' then
    raise exception 'El turno de esta factura ya se cerró: no se puede anular.';
  end if;

  v_motivo := 'venta: anulación de factura #' || v_f.numero || ' de caja';
  perform set_config('app.factura_caja', v_motivo, true);
  for v_it in select * from jsonb_array_elements(v_f.items) loop
    v_qty := (v_it ->> 'cantidad')::numeric;
    select * into v_inv from inventario where id = (v_it ->> 'inventario_id')::uuid for update;
    if not found then continue; end if;   -- producto borrado del inventario: no hay a dónde devolver
    if v_inv.desc_dia = (v_it ->> 'desc_dia')::date and coalesce(v_inv.desc_hoy, 0) >= v_qty then
      update inventario set cantidad = coalesce(cantidad, 0) + v_qty, desc_hoy = desc_hoy - v_qty, updated_at = now(),
             mov_motivo = v_motivo
       where id = v_inv.id;
    elsif v_admin then
      update inventario set cantidad = coalesce(cantidad, 0) + v_qty, updated_at = now(),
             mov_motivo = 'ajuste: anulación de factura #' || v_f.numero || ' de caja'
       where id = v_inv.id;
    else
      raise exception 'La venta de % es de otro día: la anulación la debe hacer un administrador.', v_inv.producto;
    end if;
  end loop;
  perform set_config('app.factura_caja', '', true);

  update facturas_caja
     set estado = 'anulada', motivo_anulacion = btrim(p_motivo), anulada_por = v_email, anulada_at = now()
   where id = p_factura;

  return jsonb_build_object('id', v_f.id, 'numero', v_f.numero);
end;
$$;
revoke all on function anular_factura_caja(uuid, text) from public;
grant execute on function anular_factura_caja(uuid, text) to authenticated;
