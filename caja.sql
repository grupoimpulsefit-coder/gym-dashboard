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
