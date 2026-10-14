-- ════════════════════════════════════════════════════════════════════════
--  MEDICIONES — opción "Solo medición" (se midió, pero sin rutina)
--  Correr UNA vez en Supabase → SQL Editor. Se puede repetir sin problema.
--
--  La columna rutina solo aceptaba 'completa' / 'incompleta'. Se agrega
--  'sin_rutina'. Como cualquier rutina marcada, deja al cliente "presente"
--  (eso ya lo hace mediciones_guard, de mediciones_asistencia.sql).
-- ════════════════════════════════════════════════════════════════════════

-- Quita la regla vieja de rutina (sea cual sea su nombre)
do $$
declare r record;
begin
  for r in select conname from pg_constraint
           where conrelid = 'mediciones'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) ilike '%rutina%'
  loop
    execute format('alter table mediciones drop constraint %I', r.conname);
  end loop;
end $$;

alter table mediciones add constraint mediciones_rutina_check
  check (rutina in ('completa', 'incompleta', 'sin_rutina'));

-- Comprobación: debe mostrar la regla con 'sin_rutina'
select conname, pg_get_constraintdef(oid) as regla
from pg_constraint
where conrelid = 'mediciones'::regclass and contype = 'c';
