-- ══════════════════════════════════════════════════════════════════════════
--  Módulo de CIERRE DE CAJA + INVENTARIO
--  Correr UNA vez en el SQL editor de Supabase.
-- ══════════════════════════════════════════════════════════════════════════

-- 1) Cierres de caja (por turno; el turno acumula al anterior) -----------------
create table if not exists cierres_caja (
  id              uuid primary key default gen_random_uuid(),
  sede            text not null,
  fecha           date not null,
  turno           text,                    -- etiqueta libre del turno (ej. "Mañana", "Tarde")
  caja_inicial    numeric default 0,       -- efectivo con que abre (por defecto = efectivo del cierre anterior)
  membresias      numeric default 0,
  total_ventas    numeric default 0,       -- TOTAL de ventas del sistema/informe
  total_tarjeta   numeric default 0,
  total_sinpe     numeric default 0,
  efectivo        numeric default 0,       -- contado (suma de billetes y monedas)
  denominaciones  jsonb,                   -- { "20000": 7, "10000": 19, ... }
  gastos          jsonb,                   -- [ { "desc": "...", "monto": 0 }, ... ]
  ingresos        jsonb,                   -- [ { "desc": "...", "monto": 0 }, ... ]
  total_gastos    numeric default 0,
  total_ingresos  numeric default 0,
  minita          numeric default 0,       -- total_ventas - membresias
  diferencia      numeric default 0,       -- total_ventas - (efectivo+tarjeta+sinpe+gastos-ingresos-caja_inicial)
  estado_dif      text,                    -- 'OK' | 'Diferencia'
  informe_ventas  jsonb,                   -- totales del Informe de Ventas cargado (validación)
  created_by      text,
  created_at      timestamptz default now()
);
create index if not exists cierres_sede_fecha_idx on cierres_caja (sede, fecha desc, created_at desc);
-- Otros/minita = total_ventas - membresias; se retira en sobres.
-- efectivo_final = efectivo contado - minita. otros_vendidos guarda el minita.
alter table cierres_caja add column if not exists efectivo_final numeric default 0;
alter table cierres_caja add column if not exists otros_vendidos numeric default 0;
-- sobre_retirado: true si el efectivo contado YA tiene el sobre (minita) retirado.
alter table cierres_caja add column if not exists sobre_retirado boolean default false;
-- Ciclo de turno: apertura obligatoria (efectivo + inventario contado) y cierre parcial/final con horas.
alter table cierres_caja add column if not exists turno_num int;
alter table cierres_caja add column if not exists estado text default 'final';   -- 'abierto' | 'parcial' | 'final'
alter table cierres_caja add column if not exists hora_apertura timestamptz;
alter table cierres_caja add column if not exists hora_cierre timestamptz;
alter table cierres_caja add column if not exists inventario_apertura jsonb;      -- conteo físico a ciegas al abrir { producto: { contado, sistema } }
alter table cierres_caja add column if not exists denominaciones_apertura jsonb;   -- desglose de billetes/monedas del efectivo inicial
-- Reporte SINPE del cierre (obligatorio en cierre final): resumen enviado/registrado/comparación.
alter table cierres_caja add column if not exists sinpe_reporte jsonb;             -- { fileName, totalN, totalMonto, yaRegN, yaRegMonto, nuevosN, nuevosMonto }

-- 2) Inventario por sede ------------------------------------------------------
create table if not exists inventario (
  id              uuid primary key default gen_random_uuid(),
  sede            text not null,
  producto        text not null,
  moneda          text default 'CRC',
  precio          numeric default 0,
  cantidad        numeric default 0,       -- stock actual/esperado
  cantidad_minima numeric default 0,       -- umbral para marcar faltante/reorden
  activo          boolean default true,
  updated_at      timestamptz default now()
);
create unique index if not exists inventario_sede_prod_idx on inventario (sede, lower(producto));
-- Control de descuento idempotente por día (el informe de ventas es acumulado del día):
-- desc_dia = día del último descuento; desc_hoy = unidades ya descontadas ese día.
alter table inventario add column if not exists desc_dia date;
alter table inventario add column if not exists desc_hoy numeric default 0;

-- ══════════════════════════════════════════════════════════════════════════
--  RLS
--  - cierres_caja: recepción (su sede) + admin/admin_sedes/admin_g (todo).
--  - inventario: solo admin/admin_sedes/admin_g (recepción no).
-- ══════════════════════════════════════════════════════════════════════════
alter table cierres_caja enable row level security;
drop policy if exists cierres_rw on cierres_caja;
create policy cierres_rw on cierres_caja
  for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
          and (ur.role in ('admin','admin_sedes','admin_g') or (ur.role='recepcion' and ur.sede = cierres_caja.sede))))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
          and (ur.role in ('admin','admin_sedes','admin_g') or (ur.role='recepcion' and ur.sede = cierres_caja.sede))));

alter table inventario enable row level security;
drop policy if exists inventario_rw on inventario;
create policy inventario_rw on inventario
  for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes','admin_g')))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes','admin_g')));

-- Recepción: puede LEER y DESCONTAR (update) el inventario de SU sede, pero no crear/borrar productos.
drop policy if exists inventario_recep_select on inventario;
create policy inventario_recep_select on inventario
  for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role = 'recepcion' and ur.sede = inventario.sede));
drop policy if exists inventario_recep_update on inventario;
create policy inventario_recep_update on inventario
  for update to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role = 'recepcion' and ur.sede = inventario.sede))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role = 'recepcion' and ur.sede = inventario.sede));

-- ══════════════════════════════════════════════════════════════════════════
--  Envíos de mercadería (admin envía → recepción acepta; suma stock al aceptar)
-- ══════════════════════════════════════════════════════════════════════════
create table if not exists envios_mercaderia (
  id           uuid primary key default gen_random_uuid(),
  sede         text not null,                 -- sede destino
  estado       text default 'pendiente',      -- 'pendiente' | 'aceptado'
  items        jsonb not null,                -- [ { producto, enviado, recibido } ]
  nota         text,                          -- nota de recepción (faltantes, etc.)
  created_by   text,
  created_at   timestamptz default now(),
  aceptado_por text,
  aceptado_at  timestamptz
);
create index if not exists envios_sede_estado_idx on envios_mercaderia (sede, estado);

alter table envios_mercaderia enable row level security;
-- Admin: crea, lee y gestiona todo
drop policy if exists envios_admin on envios_mercaderia;
create policy envios_admin on envios_mercaderia
  for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes','admin_g')))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes','admin_g')));
-- Recepción: ve y acepta (update) los envíos de SU sede; no puede crearlos
drop policy if exists envios_recep_select on envios_mercaderia;
create policy envios_recep_select on envios_mercaderia
  for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role = 'recepcion' and ur.sede = envios_mercaderia.sede));
drop policy if exists envios_recep_update on envios_mercaderia;
create policy envios_recep_update on envios_mercaderia
  for update to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role = 'recepcion' and ur.sede = envios_mercaderia.sede))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role = 'recepcion' and ur.sede = envios_mercaderia.sede));

-- ══════════════════════════════════════════════════════════════════════════
--  Registro de SINPE (reporte SINPE Móvil): dedup por ReferenciaSinpe.
--  El reporte es un rango de fechas acumulado; se guardan las referencias ya
--  contadas para que al recargarlo otro día solo se tomen los SINPE nuevos.
-- ══════════════════════════════════════════════════════════════════════════
create table if not exists sinpe_registrados (
  id          uuid primary key default gen_random_uuid(),
  sede        text not null,
  referencia  text not null,               -- ReferenciaSinpe (único por sede)
  monto       numeric default 0,
  fecha_tx    text,                         -- fecha de transacción del reporte
  detalle     text,
  cierre_id   uuid,                         -- cierre en el que se registró
  created_by  text,
  created_at  timestamptz default now()
);
create unique index if not exists sinpe_reg_sede_ref_idx on sinpe_registrados (sede, referencia);

alter table sinpe_registrados enable row level security;
drop policy if exists sinpe_rw on sinpe_registrados;
create policy sinpe_rw on sinpe_registrados
  for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
          and (ur.role in ('admin','admin_sedes','admin_g') or (ur.role='recepcion' and ur.sede = sinpe_registrados.sede))))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
          and (ur.role in ('admin','admin_sedes','admin_g') or (ur.role='recepcion' and ur.sede = sinpe_registrados.sede))));
