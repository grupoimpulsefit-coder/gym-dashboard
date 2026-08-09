-- ══════════════════════════════════════════════════════════════════════════
--  Módulo de RRHH — empleados, salarios, vacaciones y portal del empleado
--  Correr UNA vez en el SQL editor de Supabase.
-- ══════════════════════════════════════════════════════════════════════════

-- Rol nuevo esperado en user_roles.role: 'empleado' (acceso solo al portal).
-- (roles existentes: 'admin', 'admin_sedes', 'colaborador', 'recepcion')

-- 1) Empleados ---------------------------------------------------------------
create table if not exists empleados (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid,                    -- id de la cuenta auth (liga el portal); null si aún no tiene acceso
  nombre            text not null,
  cedula            text,                    -- ID / cédula
  correo            text,                    -- correo (se usa para ligar la cuenta del portal)
  telefono          text,
  direccion         text,
  cuenta_bac        text,                    -- número de cuenta BAC
  sede              text not null,           -- '3 Ríos' | 'Natación' | 'Pinares' | 'Sabanilla'
  salario_mensual   numeric,
  salario_quincenal numeric,                 -- por defecto mensual/2 (editable)
  fecha_ingreso     date,
  vac_dias_por_mes  numeric default 1,       -- tasa de acumulación de vacaciones (días por mes trabajado)
  vac_ajuste        numeric default 0,       -- ajuste manual del saldo (+/- días)
  activo            boolean default true,
  created_at        timestamptz default now()
);
create index if not exists empleados_sede_idx on empleados (sede);
create index if not exists empleados_user_idx on empleados (user_id);

-- 2) Solicitudes de vacaciones / días libres --------------------------------
create table if not exists vacaciones_solicitudes (
  id             uuid primary key default gen_random_uuid(),
  empleado_id    uuid references empleados(id),
  user_id        uuid,                       -- quién solicita (auth id) — para RLS del portal
  sede           text,
  fecha_inicio   date not null,
  fecha_fin      date not null,
  dias           numeric not null,           -- días solicitados
  motivo         text,
  estado         text default 'pendiente',   -- 'pendiente' | 'aprobada' | 'rechazada'
  comentario_admin text,
  resuelto_por   text,
  resuelto_at    timestamptz,
  created_at     timestamptz default now()
);
create index if not exists vac_empleado_idx on vacaciones_solicitudes (empleado_id);
create index if not exists vac_user_idx on vacaciones_solicitudes (user_id);

-- ══════════════════════════════════════════════════════════════════════════
--  Row Level Security
--  - admin / admin_sedes: gestionan todo.
--  - empleado: ve SOLO su propia ficha y sus propias solicitudes; puede crear
--    solicitudes propias, pero no cambiar su estado (eso lo hace el admin).
-- ══════════════════════════════════════════════════════════════════════════
alter table empleados enable row level security;

drop policy if exists empleados_admin_all on empleados;
create policy empleados_admin_all on empleados
  for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes')))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes')));

drop policy if exists empleados_self_select on empleados;
create policy empleados_self_select on empleados
  for select to authenticated
  using (user_id = auth.uid());

alter table vacaciones_solicitudes enable row level security;

drop policy if exists vac_admin_all on vacaciones_solicitudes;
create policy vac_admin_all on vacaciones_solicitudes
  for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes')))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes')));

drop policy if exists vac_self_select on vacaciones_solicitudes;
create policy vac_self_select on vacaciones_solicitudes
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists vac_self_insert on vacaciones_solicitudes;
create policy vac_self_insert on vacaciones_solicitudes
  for insert to authenticated
  with check (user_id = auth.uid() and estado = 'pendiente');
