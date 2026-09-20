-- ══════════════════════════════════════════════════════════════════════════
--  RRHH — pago semanal por horas (servicios profesionales)
--  Correr UNA vez en el SQL editor de Supabase. Se puede repetir sin problema.
--
--  Para instructores que facturan por servicios profesionales y cobran por
--  semana: se pactan las HORAS de la semana y el MONTO POR HORA.
--    pago de la semana  = horas_semana * monto_hora
--    equivalente mensual = pago semanal * 52 / 12   (4,333 semanas por mes)
--  El equivalente mensual es el que usa la planilla, la CCSS y la liquidación.
-- ══════════════════════════════════════════════════════════════════════════

alter table empleados add column if not exists tipo_pago    text default 'mensual';
alter table empleados add column if not exists monto_hora   numeric;
alter table empleados add column if not exists horas_semana numeric;

-- Los empleados que ya existían quedan como estaban: planilla mensual.
update empleados set tipo_pago = 'mensual' where tipo_pago is null;

-- Solo se aceptan las dos modalidades conocidas.
do $$ begin
  alter table empleados add constraint empleados_tipo_pago_chk check (tipo_pago in ('mensual','semanal'));
exception when duplicate_object then null; end $$;

-- Comprobación: debería listar las 3 columnas nuevas.
select column_name, data_type, column_default
from information_schema.columns
where table_name = 'empleados'
  and column_name in ('tipo_pago','monto_hora','horas_semana')
order by column_name;
