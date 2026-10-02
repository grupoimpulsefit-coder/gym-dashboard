-- ══════════════════════════════════════════════════════════════════════════
--  Módulo de PLANILLA — pago quincenal por sede
--  Correr UNA vez en el SQL editor de Supabase. Se puede repetir sin problema.
--
--  La base sale de RRHH (tabla empleados: salario_mensual / salario_quincenal,
--  asegurado_ccss, fecha_ingreso). Aquí solo se guardan:
--    · las NOVEDADES de cada quincena (feriados trabajados, incapacidades,
--      permisos sin goce, bonos y otras deducciones), y
--    · el CIERRE de cada quincena: una foto (snapshot) de lo que se pagó, para
--      que un cambio de salario posterior no altere el histórico.
--
--  Periodo: 'YYYY-MM-Q1' (días 1 al 15) | 'YYYY-MM-Q2' (16 al fin de mes).
-- ══════════════════════════════════════════════════════════════════════════

-- 1) Novedades de la quincena ------------------------------------------------
create table if not exists planilla_novedades (
  id            uuid primary key default gen_random_uuid(),
  empleado_id   uuid not null references empleados(id) on delete cascade,
  sede          text not null,
  periodo       text not null,              -- '2026-10-Q1'
  tipo          text not null,              -- 'feriado' | 'incapacidad' | 'sin_goce' | 'bono' | 'deduccion'
  fecha_inicio  date,
  fecha_fin     date,
  dias          numeric default 0,          -- días afectados (feriado, incapacidad, sin goce)
  factor        numeric,                    -- feriado: veces el salario diario a sumar (1 = se paga doble)
  ente          text,                       -- incapacidad: 'ccss' | 'ins' | 'maternidad'
  dias_patrono  numeric,                    -- incapacidad: días que subsidia el patrono
  pct_patrono   numeric,                    -- incapacidad: % del salario diario que paga el patrono
  monto         numeric default 0,          -- monto calculado (o manual en bono / deducción), siempre positivo
  nota          text,
  created_by    text,
  created_at    timestamptz default now()
);
create index if not exists planilla_nov_periodo_idx on planilla_novedades (sede, periodo);
create index if not exists planilla_nov_emp_idx on planilla_novedades (empleado_id);

do $$ begin
  alter table planilla_novedades add constraint planilla_nov_tipo_chk
    check (tipo in ('feriado','incapacidad','sin_goce','bono','deduccion'));
exception when duplicate_object then null; end $$;

-- 2) Cierre de quincena (snapshot) --------------------------------------------
create table if not exists planilla_periodos (
  id            uuid primary key default gen_random_uuid(),
  sede          text not null,
  periodo       text not null,              -- '2026-10-Q1'
  fecha_inicio  date not null,
  fecha_fin     date not null,
  estado        text default 'cerrada',     -- 'cerrada' (si se reabre, se borra la fila)
  detalle       jsonb,                      -- líneas por empleado tal como se pagaron
  total_bruto   numeric,
  total_ccss    numeric,
  total_neto    numeric,
  total_patrono numeric,
  cerrada_por   text,
  cerrada_at    timestamptz default now(),
  unique (sede, periodo)
);

-- ══════════════════════════════════════════════════════════════════════════
--  Row Level Security — igual que empleados: solo admin / admin_sedes.
-- ══════════════════════════════════════════════════════════════════════════
alter table planilla_novedades enable row level security;
drop policy if exists planilla_nov_admin_all on planilla_novedades;
create policy planilla_nov_admin_all on planilla_novedades
  for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes')))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes')));

alter table planilla_periodos enable row level security;
drop policy if exists planilla_per_admin_all on planilla_periodos;
create policy planilla_per_admin_all on planilla_periodos
  for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes')))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes')));

-- Comprobación: deberían aparecer las 2 tablas.
select table_name from information_schema.tables
where table_name in ('planilla_novedades','planilla_periodos') order by table_name;
