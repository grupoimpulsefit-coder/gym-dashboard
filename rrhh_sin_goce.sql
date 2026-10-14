-- ══════════════════════════════════════════════════════════════════════════
--  RRHH — días libres SIN goce de salario
--  Correr UNA vez en Supabase → SQL Editor. Se puede repetir sin problema.
--
--  Las solicitudes de días libres pueden ser:
--    · 'vacaciones' → con goce; rebajan el saldo de vacaciones (lo de siempre)
--    · 'sin_goce'   → no rebajan el saldo; se descuentan del salario en Planilla
--  Las solicitudes que ya existen quedan como 'vacaciones'.
-- ══════════════════════════════════════════════════════════════════════════

alter table vacaciones_solicitudes add column if not exists tipo text not null default 'vacaciones';

do $$ begin
  alter table vacaciones_solicitudes add constraint vac_tipo_chk check (tipo in ('vacaciones','sin_goce'));
exception when duplicate_object then null; end $$;

-- Comprobación: cuántas hay de cada tipo
select tipo, count(*) from vacaciones_solicitudes group by tipo order by tipo;
