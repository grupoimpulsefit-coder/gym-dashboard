-- ══════════════════════════════════════════════════════════════════════════
--  RRHH — vacaciones de los administradores
--  Correr en Supabase → SQL Editor, después de rrhh.sql y rrhh_sin_goce.sql.
--  Se puede repetir sin problema.
--
--  · Los administradores también son empleados: con su cuenta ligada a su
--    ficha, piden vacaciones desde «Mi Portal» como cualquier empleado.
--  · Nadie aprueba (ni registra como aprobadas) sus PROPIAS vacaciones:
--    las aprueba otro administrador. Lo valida este trigger.
--  · Un administrador puede registrar días ya aprobados a cualquier otro
--    empleado (botón «Registrar días» en Solicitudes de días libres).
-- ══════════════════════════════════════════════════════════════════════════

create or replace function vac_no_autoaprobar()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  dueno uuid;
begin
  if auth.uid() is null then return new; end if;    -- procesos del servidor
  select e.user_id into dueno from empleados e where e.id = new.empleado_id;
  if dueno is not null and dueno = auth.uid() and new.estado <> 'pendiente'
     and (tg_op = 'INSERT' or new.estado is distinct from old.estado) then
    raise exception 'Sus propias vacaciones las aprueba otro administrador.' using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists vac_no_autoaprobar_trg on vacaciones_solicitudes;
create trigger vac_no_autoaprobar_trg
  before insert or update on vacaciones_solicitudes
  for each row execute function vac_no_autoaprobar();

-- Comprobación
select tgname from pg_trigger where tgname = 'vac_no_autoaprobar_trg';
