-- ══════════════════════════════════════════════════════════════════════════
--  Módulo de GASTOS — recepción carga gastos por sede
--  Correr UNA vez en el SQL editor de Supabase.
-- ══════════════════════════════════════════════════════════════════════════

-- 1) Rol de recepción por sede ------------------------------------------------
--    Cada correo NO administrador se asocia a una sede. Los correos
--    admin / admin_sedes dejan sede = NULL (ven todas las sedes).
--    Rol nuevo esperado en user_roles.role: 'recepcion'
--    (roles existentes: 'admin', 'admin_sedes', 'colaborador').
alter table user_roles add column if not exists sede text;

-- 2) Directorio de instructores (compartido entre todas las sedes) ------------
--    Autocompleta los datos de pago en el formulario de gastos.
create table if not exists instructores (
  id           uuid primary key default gen_random_uuid(),
  nombre       text not null,
  cuenta_bac   text,            -- número de cuenta BAC (para pago)
  otro_banco   text,            -- nombre del otro banco (si no usa BAC)
  cuenta_otro  text,            -- número de cuenta del otro banco
  sinpe_movil  text,            -- número de SINPE Móvil
  activo       boolean default true,
  created_at   timestamptz default now()
);
-- nombre único sin importar mayúsculas/acentos básicos
create unique index if not exists instructores_nombre_uidx on instructores (lower(nombre));

-- 3) Gastos por sede, categoría y mes -----------------------------------------
create table if not exists gastos (
  id              uuid primary key default gen_random_uuid(),
  sede            text not null,          -- '3 Ríos' | 'Natación' | 'Pinares' | 'Sabanilla'
  categoria       text not null,          -- 'clases_grupales' | 'instructores_planta'
  fecha_clase     date not null,          -- día de la fecha de la clase
  mes             text not null,          -- 'Agosto 2026' (etiqueta para el resumen mensual)
  mes_orden       text,                   -- '2026-08' (para ordenar/filtrar)
  emisor          text not null,          -- nombre del emisor de la factura
  instructor_id   uuid references instructores(id),
  documento_cobro text,                   -- documento de cobro
  numero_factura  text,                   -- número de factura
  monto           numeric not null,
  metodo_pago     text,                   -- 'bac' | 'otro_banco' | 'sinpe'
  banco_pago      text,                   -- 'BAC' | nombre del otro banco | 'SINPE Móvil'
  cuenta_pago     text,                   -- cuenta o número usado (snapshot al registrar)
  created_by      text,                   -- correo de quien registró el gasto
  created_at      timestamptz default now()
);
create index if not exists gastos_sede_mes_idx on gastos (sede, mes_orden);

-- ══════════════════════════════════════════════════════════════════════════
--  Row Level Security (RLS)
--  Las tablas quedan con RLS activado; estas políticas autorizan las
--  operaciones que hace la app con el JWT del usuario (rol 'authenticated').
--  Los gastos se restringen por sede para el rol recepción.
--  Es idempotente: se puede correr varias veces sin error.
--  (Requiere que user_roles sea legible por el usuario autenticado para el
--   subquery; hoy user_roles no usa RLS, así que funciona.)
-- ──────────────────────────────────────────────────────────────────────────

-- ── Instructores: directorio compartido; cualquier autenticado lee y crea ──
alter table instructores enable row level security;

drop policy if exists instructores_select on instructores;
create policy instructores_select on instructores
  for select to authenticated using (true);

drop policy if exists instructores_insert on instructores;
create policy instructores_insert on instructores
  for insert to authenticated with check (true);

-- Editar instructores: solo admin / admin_sedes
drop policy if exists instructores_update on instructores;
create policy instructores_update on instructores
  for update to authenticated
  using (
    exists (select 1 from user_roles ur where ur.id = auth.uid()
            and ur.role in ('admin','admin_sedes','admin_g'))
  )
  with check (
    exists (select 1 from user_roles ur where ur.id = auth.uid()
            and ur.role in ('admin','admin_sedes','admin_g'))
  );

-- Eliminar instructores: solo admin / admin_sedes / admin_g
drop policy if exists instructores_delete on instructores;
create policy instructores_delete on instructores
  for delete to authenticated
  using (
    exists (select 1 from user_roles ur where ur.id = auth.uid()
            and ur.role in ('admin','admin_sedes','admin_g'))
  );

-- ── Gastos: admin ve/edita todo; recepción SOLO su sede ──
alter table gastos enable row level security;

drop policy if exists gastos_select on gastos;
create policy gastos_select on gastos
  for select to authenticated
  using (
    exists (select 1 from user_roles ur where ur.id = auth.uid()
            and (ur.role in ('admin','admin_sedes','admin_g')
                 or (ur.role in ('recepcion','admin_sucursal') and ur.sede = gastos.sede)))
  );

drop policy if exists gastos_insert on gastos;
create policy gastos_insert on gastos
  for insert to authenticated
  with check (
    exists (select 1 from user_roles ur where ur.id = auth.uid()
            and (ur.role in ('admin','admin_sedes','admin_g')
                 or (ur.role in ('recepcion','admin_sucursal') and ur.sede = gastos.sede)))
  );

-- Solo admin / admin_sedes pueden eliminar gastos (recepción no)
drop policy if exists gastos_delete on gastos;
create policy gastos_delete on gastos
  for delete to authenticated
  using (
    exists (select 1 from user_roles ur where ur.id = auth.uid()
            and ur.role in ('admin','admin_sedes','admin_g'))
  );

-- Solo admin / admin_sedes pueden editar (modificar) gastos ya registrados
drop policy if exists gastos_update on gastos;
create policy gastos_update on gastos
  for update to authenticated
  using (
    exists (select 1 from user_roles ur where ur.id = auth.uid()
            and ur.role in ('admin','admin_sedes','admin_g'))
  )
  with check (
    exists (select 1 from user_roles ur where ur.id = auth.uid()
            and ur.role in ('admin','admin_sedes','admin_g'))
  );
