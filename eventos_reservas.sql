-- ══════════════════════════════════════════════════════════════════════════
--  CAJA — Eventos: reservas con un % del total, abonos y cancelación del saldo
--  Correr en Supabase → SQL Editor, DESPUÉS de eventos.sql.
--  Se puede repetir sin problema.
--
--  · El administrador pone en cada evento el % mínimo para reservar
--    (eventos_caja.reserva_pct). Vacío = el evento solo se vende completo.
--  · Recepción cobra el evento completo (como antes) o RESERVA pagando al
--    menos ese %. Queda una reserva con su saldo pendiente.
--  · Después se hacen ABONOS al saldo, o se CANCELA (paga) todo el saldo, en
--    cualquier sede donde se vende el evento.
--  · Cada pago (reserva, abono, cancelación) es un cobro de evento en
--    facturas_caja con reserva_id: entra al cierre del turno en su método de
--    pago, igual que los cobros de eventos de siempre (no va al sobre).
--  · Lo pagado de la reserva se recalcula solo con los cobros no anulados.
--    Si se anulan todos sus cobros, la reserva queda anulada.
-- ══════════════════════════════════════════════════════════════════════════

alter table eventos_caja add column if not exists reserva_pct numeric;
alter table eventos_caja drop constraint if exists eventos_reserva_pct_ok;
alter table eventos_caja add constraint eventos_reserva_pct_ok
  check (reserva_pct is null or (reserva_pct > 0 and reserva_pct < 100));

create table if not exists eventos_reservas (
  id               uuid primary key default gen_random_uuid(),
  evento_id        uuid not null references eventos_caja(id),
  sede             text not null,                    -- sede donde se reservó
  tipo_precio      text not null check (tipo_precio in ('miembro','no_miembro')),
  cliente_nombre   text,
  cliente_telefono text,
  cliente_pin      text,
  total            numeric not null check (total > 0),
  pagado           numeric not null default 0,
  estado           text not null default 'pendiente' check (estado in ('pendiente','pagada','anulada')),
  created_by       text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists eventos_reservas_evento_idx on eventos_reservas (evento_id, estado);

alter table eventos_reservas enable row level security;
drop policy if exists eventos_reservas_select on eventos_reservas;
create policy eventos_reservas_select on eventos_reservas
  for select to authenticated
  using (public.mi_rol() in ('admin','admin_sedes','admin_g','recepcion','admin_sucursal','coordinador'));
-- Sin políticas de escritura: solo se crean y cambian con las funciones de abajo.

alter table facturas_caja add column if not exists reserva_id uuid references eventos_reservas(id);
create index if not exists facturas_caja_reserva_idx on facturas_caja (reserva_id);

-- ── Lo pagado de la reserva sale de sus cobros no anulados ────────────────
create or replace function eventos_reserva_recalcular()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_id  uuid := coalesce(new.reserva_id, old.reserva_id);
  v_pag numeric;
  v_n   int;
begin
  if v_id is null then return null; end if;
  select coalesce(sum(total) filter (where estado <> 'anulada'), 0), count(*) filter (where estado <> 'anulada')
    into v_pag, v_n from facturas_caja where reserva_id = v_id;
  update eventos_reservas r
     set pagado = v_pag,
         estado = case when v_n = 0 then 'anulada' when v_pag >= r.total then 'pagada' else 'pendiente' end,
         updated_at = now()
   where r.id = v_id;
  return null;
end $$;
drop trigger if exists facturas_caja_reserva_trg on facturas_caja;
create trigger facturas_caja_reserva_trg
  after insert or update of estado, total on facturas_caja
  for each row when (new.reserva_id is not null)
  execute function eventos_reserva_recalcular();

-- ── Cobrar un evento: completo (como antes) o reserva con p_monto ─────────
drop function if exists vender_evento_caja(uuid, uuid, text, text, text, text, text, numeric, text);
create or replace function vender_evento_caja(p_cierre uuid, p_evento uuid, p_tipo_precio text, p_metodo text,
                                              p_nombre text default null, p_telefono text default null,
                                              p_pin text default null, p_recibido numeric default null,
                                              p_referencia text default null, p_monto numeric default null)
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
  v_cobro  numeric;
  v_minimo numeric;
  v_res    uuid;
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

  -- Reserva: paga solo una parte (al menos el % del evento)
  v_cobro := v_precio;
  if p_monto is not null and round(p_monto) < v_precio then
    if coalesce(v_e.reserva_pct, 0) <= 0 then
      raise exception 'El evento % no acepta reservas: se cobra completo (₡%).', v_e.nombre, v_precio;
    end if;
    v_minimo := ceil(v_precio * v_e.reserva_pct / 100);
    if round(p_monto) < v_minimo then
      raise exception 'Para reservar se paga al menos el % %% (₡%).', v_e.reserva_pct, v_minimo;
    end if;
    v_cobro := round(p_monto);
    insert into eventos_reservas (evento_id, sede, tipo_precio, cliente_nombre, cliente_telefono, cliente_pin, total, created_by)
    values (v_e.id, v_c.sede, p_tipo_precio, v_nombre, v_tel, v_pin, v_precio, v_email)
    returning id into v_res;
  end if;

  if p_metodo = 'efectivo' and p_recibido is not null and p_recibido < v_cobro then
    raise exception 'El efectivo recibido (₡%) no cubre el monto (₡%).', p_recibido, v_cobro;
  end if;

  select coalesce(max(numero), 0) + 1 into v_num from facturas_caja where sede = v_c.sede and fecha = v_c.fecha;

  insert into facturas_caja (sede, fecha, numero, cierre_id, metodo, items, total, recibido, referencia, created_by,
                             tipo, evento_id, tipo_precio, cliente_nombre, cliente_telefono, cliente_pin, reserva_id)
  values (v_c.sede, v_c.fecha, v_num, v_c.id, p_metodo,
          jsonb_build_array(jsonb_build_object('evento_id', v_e.id,
                                               'producto', v_e.nombre || case when v_res is not null then ' · reserva' else '' end,
                                               'cantidad', 1, 'precio', v_cobro, 'total', v_cobro)),
          v_cobro, case when p_metodo = 'efectivo' then p_recibido end,
          case when p_metodo = 'sinpe' then v_ref end, v_email,
          'evento', v_e.id, p_tipo_precio, v_nombre, v_tel, v_pin, v_res)
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'numero', v_num, 'total', v_cobro, 'nombre', v_nombre,
                            'reserva_id', v_res, 'precio', v_precio, 'saldo', v_precio - v_cobro);
end;
$$;
revoke all on function vender_evento_caja(uuid, uuid, text, text, text, text, text, numeric, text, numeric) from public, anon;
grant execute on function vender_evento_caja(uuid, uuid, text, text, text, text, text, numeric, text, numeric) to authenticated;

-- ── Abonar a una reserva o cancelar todo el saldo (p_monto null = todo) ───
create or replace function abonar_reserva_evento(p_cierre uuid, p_reserva uuid, p_metodo text,
                                                 p_monto numeric default null, p_recibido numeric default null,
                                                 p_referencia text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_rol   text := public.mi_rol();
  v_email text := auth.jwt() ->> 'email';
  v_c     cierres_caja%rowtype;
  v_r     eventos_reservas%rowtype;
  v_e     eventos_caja%rowtype;
  v_ref   text := nullif(btrim(coalesce(p_referencia, '')), '');
  v_saldo numeric;
  v_monto numeric;
  v_num   int;
  v_id    uuid;
  v_etq   text;
begin
  select * into v_c from cierres_caja where id = p_cierre for update;
  if not found then raise exception 'El turno no existe.'; end if;
  if v_c.estado <> 'abierto' then raise exception 'El turno ya está cerrado. Abra un turno para cobrar.'; end if;
  if not (v_rol in ('admin','admin_sedes','admin_g') or exists (
      select 1 from user_roles ur where ur.id = auth.uid()
        and ur.role in ('recepcion','admin_sucursal','coordinador')
        and (ur.sede = v_c.sede or v_c.sede = any(ur.sedes_extra)))) then
    raise exception 'No puede cobrar en esta sede.' using errcode = '42501';
  end if;

  select * into v_r from eventos_reservas where id = p_reserva for update;   -- serializa los abonos de la reserva
  if not found then raise exception 'La reserva no existe.'; end if;
  if v_r.estado = 'pagada' then raise exception 'Esta reserva ya está pagada por completo.'; end if;
  if v_r.estado = 'anulada' then raise exception 'Esta reserva está anulada.'; end if;
  select * into v_e from eventos_caja where id = v_r.evento_id;
  if not (v_c.sede = any(v_e.sedes)) then raise exception 'El evento % no se cobra en %.', v_e.nombre, v_c.sede; end if;
  if not (p_metodo = any(v_e.metodos)) then raise exception 'Este evento no acepta pago con %.', p_metodo; end if;
  if p_metodo = 'sinpe' and (v_ref is null or length(regexp_replace(v_ref, '\D', '', 'g')) < 4) then
    raise exception 'Anote la referencia del SINPE (al menos los últimos 4 dígitos).';
  end if;

  v_saldo := v_r.total - v_r.pagado;
  v_monto := coalesce(round(p_monto), v_saldo);
  if v_monto <= 0 then raise exception 'Anote el monto del abono.'; end if;
  if v_monto > v_saldo then raise exception 'El abono (₡%) es mayor que el saldo pendiente (₡%).', v_monto, v_saldo; end if;
  if p_metodo = 'efectivo' and p_recibido is not null and p_recibido < v_monto then
    raise exception 'El efectivo recibido (₡%) no cubre el monto (₡%).', p_recibido, v_monto;
  end if;
  v_etq := case when v_monto = v_saldo then ' · cancelación del saldo' else ' · abono' end;

  select coalesce(max(numero), 0) + 1 into v_num from facturas_caja where sede = v_c.sede and fecha = v_c.fecha;
  insert into facturas_caja (sede, fecha, numero, cierre_id, metodo, items, total, recibido, referencia, created_by,
                             tipo, evento_id, tipo_precio, cliente_nombre, cliente_telefono, cliente_pin, reserva_id)
  values (v_c.sede, v_c.fecha, v_num, v_c.id, p_metodo,
          jsonb_build_array(jsonb_build_object('evento_id', v_e.id, 'producto', v_e.nombre || v_etq,
                                               'cantidad', 1, 'precio', v_monto, 'total', v_monto)),
          v_monto, case when p_metodo = 'efectivo' then p_recibido end,
          case when p_metodo = 'sinpe' then v_ref end, v_email,
          'evento', v_e.id, v_r.tipo_precio, v_r.cliente_nombre, v_r.cliente_telefono, v_r.cliente_pin, v_r.id)
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'numero', v_num, 'total', v_monto, 'nombre', v_r.cliente_nombre,
                            'saldo', v_saldo - v_monto, 'evento', v_e.nombre);
end;
$$;
revoke all on function abonar_reserva_evento(uuid, uuid, text, numeric, numeric, text) from public, anon;
grant execute on function abonar_reserva_evento(uuid, uuid, text, numeric, numeric, text) to authenticated;

-- Comprobación
select proname, pg_get_function_identity_arguments(oid) from pg_proc
 where proname in ('vender_evento_caja', 'abonar_reserva_evento') order by 1;
