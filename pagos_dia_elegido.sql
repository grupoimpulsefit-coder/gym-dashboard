-- ══════════════════════════════════════════════════════════════════════════
--  DÍA DE PAGO ELEGIDO A MANO (facturas y recibos de instructores)
--  Correr en Supabase → SQL Editor, DESPUÉS de recibos_plantillas.sql.
--  Se puede repetir sin problema.
--
--  · Al aceptar una factura se puede elegir el miércoles o viernes en que se
--    paga (p. ej. la factura llegó antes por WhatsApp). Si no se elige, sigue
--    la regla de siempre: corte miércoles y viernes a las 12 mediodía.
--  · Solo se acepta un miércoles o viernes desde hoy y hasta 4 semanas;
--    cualquier otra fecha se ignora y se calcula sola.
--  · Al editar un gasto se conserva el día que ya tenía, salvo que se cambie
--    a otro día válido. Así una factura de caja se puede pasar a transferencia.
-- ══════════════════════════════════════════════════════════════════════════

create or replace function dia_pago_valido(p_dia date)
returns boolean language sql stable set search_path = public as $$
  select p_dia is not null
     and extract(isodow from p_dia) in (3, 5)
     and p_dia between (now() at time zone 'America/Costa_Rica')::date
                   and (now() at time zone 'America/Costa_Rica')::date + 28;
$$;

create or replace function gastos_xml_dia_pago()
returns trigger language plpgsql set search_path = public as $$
declare
  recibida timestamptz;
begin
  if new.origen is null or new.origen not in ('xml', 'recibo') then return new; end if;
  if tg_op = 'INSERT' then
    -- Enviada por el instructor: el corte se mide con la hora en que la envió
    if new.factura_pendiente_id is not null then
      select p.created_at into recibida from facturas_pendientes p
       where p.id = new.factura_pendiente_id and p.estado = 'pendiente';
    end if;
    new.cargado_at := coalesce(recibida, now());
    new.pagado_at  := null;
    new.pagado_por := null;
  else
    new.cargado_at := old.cargado_at;
  end if;
  if new.pago_tipo = 'caja' then
    new.dia_pago := null;
    return new;
  end if;
  new.pago_tipo := 'transferencia';
  if tg_op = 'UPDATE' and new.dia_pago is not distinct from old.dia_pago and old.dia_pago is not null then
    return new;                                   -- no se tocó el día: se queda
  end if;
  if not dia_pago_valido(new.dia_pago) then        -- no se eligió (o no vale): automático
    new.dia_pago := dia_pago_instructor(coalesce(new.cargado_at, now()));
  end if;
  return new;
end $$;

-- Comprobación: el próximo día automático y si el próximo viernes es elegible
select dia_pago_instructor(now()) as automatico_ahora,
       dia_pago_valido(((now() at time zone 'America/Costa_Rica')::date + ((5 - extract(isodow from now() at time zone 'America/Costa_Rica')::int + 7) % 7))) as viernes_elegible;
