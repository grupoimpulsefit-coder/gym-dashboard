-- ════════════════════════════════════════════════════════════════════════
--  MEDICIONES — instructor que hizo la medición + ficha del cliente
--  Correr UNA vez en Supabase → SQL Editor, después de mediciones_asistencia.sql.
--  Se puede repetir sin problema.
--
--  1. Instructor: al marcar la rutina (completa / incompleta / solo medición)
--     se guarda el NOMBRE de quien la marcó (rutina_por_nombre), además del
--     correo que ya se guardaba (rutina_por). Lo sella el servidor: no se
--     puede falsear desde la página.
--  2. Ficha (opcional): objetivos, días que puede entrenar y condición
--     médica. Los pueden escribir recepción al agendar y el instructor
--     durante la medición.
-- ════════════════════════════════════════════════════════════════════════

alter table mediciones add column if not exists rutina_por_nombre text;
alter table mediciones add column if not exists objetivos        text;
alter table mediciones add column if not exists dias_entreno     text;
alter table mediciones add column if not exists condicion_medica text;

-- Misma guardia de mediciones_asistencia.sql, más el nombre del instructor
create or replace function mediciones_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role   text;
  v_nombre text;
  v_email  text;
  v_hoy    date := (now() at time zone 'America/Costa_Rica')::date;
begin
  select role, nombre into v_role, v_nombre from user_roles where id = auth.uid();
  v_email  := coalesce(auth.jwt() ->> 'email', '');
  v_nombre := coalesce(nullif(v_nombre, ''), v_email);

  if TG_OP = 'INSERT' then
    new.agendado_por := coalesce(nullif(new.agendado_por, ''), v_email);
    new.created_at := now();
    new.updated_at := now();
    new.rutina_por := null; new.rutina_por_nombre := null; new.rutina_at := null;
    if new.rutina is not null then
      new.rutina_por := v_email;
      new.rutina_por_nombre := v_nombre;
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
    -- El instructor marca la rutina, la asistencia "presente" y la ficha
    -- (objetivos, días, condición médica); lo demás se revierte.
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

  -- Quién hizo la medición: solo cambia cuando cambia la rutina
  if new.rutina is distinct from old.rutina then
    new.rutina_por        := case when new.rutina is null then null else v_email  end;
    new.rutina_por_nombre := case when new.rutina is null then null else v_nombre end;
    new.rutina_at         := case when new.rutina is null then null else now()    end;
  else
    new.rutina_por        := old.rutina_por;
    new.rutina_por_nombre := old.rutina_por_nombre;
    new.rutina_at         := old.rutina_at;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists mediciones_guard_trg on mediciones;
create trigger mediciones_guard_trg
  before insert or update on mediciones
  for each row execute function mediciones_guard();

-- Mediciones ya marcadas: llenar el nombre a partir del correo guardado
-- (se desactiva la guardia un momento para no tocar updated_at ni nada más)
alter table mediciones disable trigger mediciones_guard_trg;
update mediciones m
   set rutina_por_nombre = ur.nombre
  from auth.users u
  join user_roles ur on ur.id = u.id
 where m.rutina_por_nombre is null
   and m.rutina_por is not null
   and lower(u.email) = lower(m.rutina_por)
   and coalesce(ur.nombre, '') <> '';
alter table mediciones enable trigger mediciones_guard_trg;

-- Comprobación: deben aparecer las 4 columnas nuevas
select column_name, data_type from information_schema.columns
where table_name = 'mediciones'
  and column_name in ('rutina_por_nombre','objetivos','dias_entreno','condicion_medica')
order by column_name;
