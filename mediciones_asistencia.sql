-- ════════════════════════════════════════════════════════════════════════
--  MEDICIONES — asistencia del cliente (presente / ausente)
--  Correr UNA vez en Supabase → SQL Editor, después de mediciones.sql.
--  Se puede repetir sin problema.
--
--  Para saber POR QUÉ una medición no se hizo:
--    · presente → lo marca recepción o el instructor
--    · ausente  → SOLO recepción (recepcion, admin_sucursal, coordinador) y
--                 administradores; el instructor no
--    · se guarda quién y cuándo lo marcó
--  Reglas que cuida la base (no se pueden saltar desde la página):
--    · la asistencia se marca desde el día de la cita (no antes)
--    · si la rutina está marcada (completa / incompleta), el cliente estuvo:
--      queda "presente" y no se le puede poner "ausente"
-- ════════════════════════════════════════════════════════════════════════

alter table mediciones add column if not exists asistencia text
  check (asistencia in ('presente','ausente'));          -- null = sin marcar
alter table mediciones add column if not exists asistencia_por text;   -- correo de quien la marcó
alter table mediciones add column if not exists asistencia_at  timestamptz;

-- Misma guardia de mediciones.sql, más las reglas de asistencia
create or replace function mediciones_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role  text;
  v_email text;
  v_hoy   date := (now() at time zone 'America/Costa_Rica')::date;
begin
  select role into v_role from user_roles where id = auth.uid();
  v_email := coalesce(auth.jwt() ->> 'email', '');

  if TG_OP = 'INSERT' then
    new.agendado_por := coalesce(nullif(new.agendado_por, ''), v_email);
    new.created_at := now();
    new.updated_at := now();
    if new.rutina is not null then
      new.rutina_por := v_email;
      new.rutina_at := now();
      new.asistencia := 'presente';
    end if;
    if new.asistencia is not null then
      if new.fecha > v_hoy then
        raise exception 'La asistencia se marca el día de la cita.';
      end if;
      new.asistencia_por := v_email;
      new.asistencia_at := now();
    end if;
    return new;
  end if;

  -- UPDATE
  if v_role = 'instructor' then
    -- El instructor solo marca la rutina y la asistencia "presente"
    new.sede := old.sede;
    new.fecha := old.fecha;
    new.hora := old.hora;
    new.nombre := old.nombre;
    new.telefono := old.telefono;
    new.pin := old.pin;
    new.nota := old.nota;
    new.agendado_por := old.agendado_por;
    new.agendado_por_nombre := old.agendado_por_nombre;
    new.created_at := old.created_at;
    if new.asistencia is distinct from old.asistencia and new.asistencia is distinct from 'presente' then
      raise exception 'Solo recepción puede marcar a un cliente como ausente o quitar la asistencia.';
    end if;
  end if;

  -- Rutina marcada = el cliente estuvo
  if new.rutina is not null and new.asistencia is distinct from 'presente' then
    if new.asistencia = 'ausente' and new.asistencia is distinct from old.asistencia then
      raise exception 'La medición tiene la rutina marcada: el cliente no puede quedar ausente. Quite la rutina primero.';
    end if;
    new.asistencia := 'presente';
  end if;

  if new.asistencia is distinct from old.asistencia then
    if new.asistencia is not null and new.fecha > v_hoy then
      raise exception 'La asistencia se marca el día de la cita.';
    end if;
    new.asistencia_por := case when new.asistencia is null then null else v_email end;
    new.asistencia_at  := case when new.asistencia is null then null else now() end;
  end if;

  if new.rutina is distinct from old.rutina then
    new.rutina_por := v_email;
    new.rutina_at := case when new.rutina is null then null else now() end;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

-- El trigger ya existe (mediciones.sql); se recrea por si acaso
drop trigger if exists mediciones_guard_trg on mediciones;
create trigger mediciones_guard_trg
  before insert or update on mediciones
  for each row execute function mediciones_guard();

-- Comprobación: deben aparecer las 3 columnas nuevas
select column_name, data_type from information_schema.columns
where table_name = 'mediciones' and column_name like 'asistencia%' order by column_name;
