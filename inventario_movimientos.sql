-- ══════════════════════════════════════════════════════════════════════════
--  INVENTARIO — kardex de movimientos
--  Correr UNA vez en el SQL editor de Supabase. Se puede repetir sin problema.
--
--  Registra TODO cambio de `inventario.cantidad` con un trigger en la base,
--  no desde la app. Eso importa: queda registrado aunque alguien edite
--  directo en Supabase, aunque no hagan el conteo inicial, o aunque en el
--  futuro otro módulo toque el stock.
--
--  Cada fila guarda cuánto había, cuánto quedó, la diferencia y quién lo hizo
--  (el correo sale del token, no del cliente).
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists inventario_movimientos (
  id               uuid primary key default gen_random_uuid(),
  inventario_id    uuid,                    -- producto afectado (puede quedar huérfano si se borra)
  sede             text not null,
  producto         text not null,
  tipo             text not null,           -- 'venta' | 'entrada' | 'ajuste' | 'alta' | 'baja'
  cantidad_antes   numeric,
  cantidad_despues numeric,
  delta            numeric,                 -- negativo = salió, positivo = entró
  motivo           text,                    -- detalle que manda la app (opcional)
  usuario          text,                    -- sellado desde el token
  created_at       timestamptz default now()
);
create index if not exists inv_mov_sede_prod_idx on inventario_movimientos (sede, lower(producto), created_at desc);
create index if not exists inv_mov_fecha_idx     on inventario_movimientos (created_at desc);

-- Pista opcional que la app manda en el mismo UPDATE para decir POR QUÉ cambió.
-- Si viene vacía (por ejemplo, una edición directa en la base), se infiere.
alter table inventario add column if not exists mov_motivo text;

-- ── Trigger: registra cada cambio de cantidad ─────────────────────────────
create or replace function inventario_mov_log()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_delta numeric; v_tipo text; v_motivo text; v_user text;
begin
  v_user := coalesce(nullif(auth.jwt() ->> 'email', ''), '(directo en base de datos)');

  if TG_OP = 'INSERT' then
    insert into inventario_movimientos
      (inventario_id, sede, producto, tipo, cantidad_antes, cantidad_despues, delta, motivo, usuario)
    values (new.id, new.sede, new.producto, 'alta', 0, coalesce(new.cantidad,0),
            coalesce(new.cantidad,0), nullif(new.mov_motivo,''), v_user);
    new.mov_motivo := null;
    return new;
  end if;

  if TG_OP = 'UPDATE' then
    if new.cantidad is distinct from old.cantidad then
      v_delta  := coalesce(new.cantidad,0) - coalesce(old.cantidad,0);
      v_motivo := nullif(new.mov_motivo,'');
      -- El tipo sale de la pista de la app. Si no hay pista, el cambio NO vino
      -- del sistema (edición directa en la base u otra vía), así que se marca
      -- como 'ajuste' aunque suba: decir 'entrada' daría a entender que llegó
      -- mercadería, y eso no consta. La única excepción es el descuento por
      -- ventas, que se reconoce porque también movió desc_hoy.
      v_tipo := case
        when v_motivo is not null and split_part(v_motivo, ':', 1) in ('venta','entrada','ajuste')
             then split_part(v_motivo, ':', 1)
        when new.desc_hoy is distinct from old.desc_hoy and v_delta < 0 then 'venta'
        else 'ajuste'
      end;
      insert into inventario_movimientos
        (inventario_id, sede, producto, tipo, cantidad_antes, cantidad_despues, delta, motivo, usuario)
      values (new.id, new.sede, new.producto, v_tipo,
              coalesce(old.cantidad,0), coalesce(new.cantidad,0), v_delta, v_motivo, v_user);
    end if;
    new.mov_motivo := null;   -- la pista no se queda pegada para el próximo cambio
    return new;
  end if;

  return new;
end;
$$;
drop trigger if exists inventario_mov_log_trg on inventario;
create trigger inventario_mov_log_trg
  before insert or update on inventario
  for each row execute function inventario_mov_log();

-- Borrar un producto también deja rastro
create or replace function inventario_mov_baja()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into inventario_movimientos
    (inventario_id, sede, producto, tipo, cantidad_antes, cantidad_despues, delta, motivo, usuario)
  values (old.id, old.sede, old.producto, 'baja', coalesce(old.cantidad,0), 0,
          -coalesce(old.cantidad,0), 'producto eliminado del inventario',
          coalesce(nullif(auth.jwt() ->> 'email',''), '(directo en base de datos)'));
  return old;
end;
$$;
drop trigger if exists inventario_mov_baja_trg on inventario;
create trigger inventario_mov_baja_trg
  after delete on inventario
  for each row execute function inventario_mov_baja();

-- ── RLS ───────────────────────────────────────────────────────────────────
-- Solo lectura desde la app: las filas las escribe el trigger (security definer).
alter table inventario_movimientos enable row level security;

drop policy if exists inv_mov_select on inventario_movimientos;
create policy inv_mov_select on inventario_movimientos
  for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('coordinador','admin_sucursal')
             and (ur.sede is null or ur.sede = inventario_movimientos.sede
                  or inventario_movimientos.sede = any(ur.sedes_extra))))));

-- ══════════════════════════════════════════════════════════════════════════
--  SIEMBRA OPCIONAL — reconstruye el historial que YA quedó registrado
--  en los cierres y los envíos. No inventa nada: solo pasa a movimientos lo
--  que se puede probar. Es idempotente (no duplica si se corre dos veces).
--  Podés saltarte esta parte si solo querés registrar de hoy en adelante.
-- ══════════════════════════════════════════════════════════════════════════

-- 1) Entradas: envíos ya aceptados
insert into inventario_movimientos
  (inventario_id, sede, producto, tipo, cantidad_antes, cantidad_despues, delta, motivo, usuario, created_at)
select i.id, e.sede, coalesce(i.producto, it->>'producto'), 'entrada',
       null, null, (it->>'recibido')::numeric,
       'siembra: envío aceptado ' || e.id::text,
       coalesce(e.aceptado_por, e.created_by, '(histórico)'),
       coalesce(e.aceptado_at, e.created_at)
from envios_mercaderia e
     cross join lateral jsonb_array_elements(e.items) it
     left join inventario i on i.sede = e.sede and lower(i.producto) = lower(it->>'producto')
where e.estado = 'aceptado'
  and (it->>'recibido') is not null
  and (it->>'recibido')::numeric > 0
  and not exists (select 1 from inventario_movimientos m
                  where m.motivo = 'siembra: envío aceptado ' || e.id::text
                    and lower(m.producto) = lower(it->>'producto'));

-- 2) Salidas: ventas del día según el desglose de la minita.
--    El informe es ACUMULATIVO del día, así que solo se toma el ÚLTIMO cierre
--    de cada día (el que tiene el total del día completo).
with ultimo_del_dia as (
  select distinct on (sede, fecha) id, sede, fecha, otros_desglose, hora_cierre
  from cierres_caja
  where otros_desglose is not null
  order by sede, fecha, turno_num desc
)
insert into inventario_movimientos
  (inventario_id, sede, producto, tipo, cantidad_antes, cantidad_despues, delta, motivo, usuario, created_at)
select i.id, u.sede, coalesce(i.producto, v.value->>'base'), 'venta',
       null, null, -((v.value->>'qty')::numeric),
       'siembra: ventas del día ' || u.fecha::text,
       '(histórico)',
       coalesce(u.hora_cierre, u.fecha::timestamptz)
from ultimo_del_dia u
     cross join lateral jsonb_each(u.otros_desglose) v
     left join inventario i on i.sede = u.sede and lower(i.producto) = lower(v.value->>'base')
where (v.value->>'qty')::numeric > 0
  and not exists (select 1 from inventario_movimientos m
                  where m.motivo = 'siembra: ventas del día ' || u.fecha::text
                    and m.sede = u.sede
                    and lower(m.producto) = lower(v.value->>'base'));

-- Comprobación
select tipo, count(*) as movimientos, min(created_at)::date as desde, max(created_at)::date as hasta
from inventario_movimientos
group by tipo
order by tipo;
