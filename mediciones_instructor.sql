-- ════════════════════════════════════════════════════════════════════════
--  MEDICIONES — instructor que ATIENDE al cliente (asignado al llegar)
--  Correr UNA vez en Supabase → SQL Editor, después de mediciones_ficha.sql.
--  Se puede repetir sin problema.
--
--  Para saber a quién presionar cuando una medición va lenta:
--    · Al marcar "presente" hay que escoger el instructor que lo atiende
--      (obligatorio). Lo escoge recepción de la lista de instructores y
--      coordinadores de la sede.
--    · Si el que marca presente (o la rutina) es el instructor, queda él.
--    · El instructor puede tomar una medición ("Yo la atiendo"): solo puede
--      asignársela a sí mismo, no a otro.
--    · Ausente / sin marcar → se quita el instructor.
--    · Quién terminó la medición sigue en rutina_por_nombre (ver
--      mediciones_ficha.sql); el asignado queda en instructor_nombre.
--  El nombre lo pone el servidor a partir de la cuenta: no se puede falsear.
-- ════════════════════════════════════════════════════════════════════════

alter table mediciones add column if not exists instructor_id     uuid;
alter table mediciones add column if not exists instructor_nombre text;
alter table mediciones add column if not exists instructor_por    text;          -- correo de quien lo asignó
alter table mediciones add column if not exists instructor_at     timestamptz;

-- ── Lista de instructores de una sede (para escoger en la página) ───────
--  user_roles no se puede leer entero desde la página; esta función devuelve
--  solo id y nombre, y solo a quien tiene acceso a esa sede.
create or replace function mediciones_instructores(p_sede text)
returns table (id uuid, nombre text, role text)
language sql
stable
security definer
set search_path = public
as $$
  select ur.id, coalesce(nullif(ur.nombre, ''), u.email::text), ur.role
    from user_roles ur
    left join auth.users u on u.id = ur.id
   where ur.role in ('instructor', 'coordinador')
     and (ur.sede = p_sede or p_sede = any(ur.sedes_extra))
     and exists (select 1 from user_roles me where me.id = auth.uid()
                  and (me.role in ('admin','admin_sedes','admin_g')
                       or (me.role in ('recepcion','admin_sucursal','coordinador','instructor')
                           and (me.sede = p_sede or p_sede = any(me.sedes_extra)))))
   order by 2;
$$;
revoke all on function mediciones_instructores(text) from public, anon;
grant execute on function mediciones_instructores(text) to authenticated;

-- ── Guardia (misma de mediciones_ficha.sql + instructor asignado) ───────
create or replace function mediciones_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_role   text;
  v_nombre text;
  v_email  text;
  v_hoy    date := (now() at time zone 'America/Costa_Rica')::date;
  v_old_asist text;
  v_old_rutina text;
  v_old_instr uuid;
  v_inom   text;
begin
  select role, nombre into v_role, v_nombre from user_roles where id = v_uid;
  v_email  := coalesce(auth.jwt() ->> 'email', '');
  v_nombre := coalesce(nullif(v_nombre, ''), v_email);

  if TG_OP = 'INSERT' then
    new.agendado_por := coalesce(nullif(new.agendado_por, ''), v_email);
    new.created_at := now();
    v_old_asist := null; v_old_rutina := null; v_old_instr := null;
    new.rutina_por := null; new.rutina_por_nombre := null; new.rutina_at := null;
    new.asistencia_por := null; new.asistencia_at := null;
    new.instructor_nombre := null; new.instructor_por := null; new.instructor_at := null;
  else
    v_old_asist := old.asistencia; v_old_rutina := old.rutina; v_old_instr := old.instructor_id;
    if v_role = 'instructor' then
      -- El instructor marca la rutina, "presente", la ficha y tomarse la
      -- medición; lo demás se revierte.
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
      if new.instructor_id is distinct from old.instructor_id and new.instructor_id is distinct from v_uid then
        raise exception 'Como instructor solo podés asignarte la medición a vos mismo.';
      end if;
    end if;
  end if;

  -- Rutina marcada = el cliente estuvo
  if new.rutina is not null and new.asistencia is distinct from 'presente' then
    if new.asistencia = 'ausente' and new.asistencia is distinct from v_old_asist then
      raise exception 'La medición tiene la rutina marcada: el cliente no puede quedar ausente. Quite la rutina primero.';
    end if;
    new.asistencia := 'presente';
  end if;

  if new.asistencia is distinct from v_old_asist then
    if new.asistencia is not null and new.fecha > v_hoy then
      raise exception 'La asistencia se marca el día de la cita.';
    end if;
    new.asistencia_por := case when new.asistencia is null then null else v_email end;
    new.asistencia_at  := case when new.asistencia is null then null else now() end;
  elsif TG_OP = 'UPDATE' then
    new.asistencia_por := old.asistencia_por;
    new.asistencia_at  := old.asistencia_at;
  end if;

  -- Instructor que atiende
  if new.asistencia is distinct from 'presente' then
    new.instructor_id := null;                       -- ausente / sin marcar: nadie lo atiende
  elsif new.instructor_id is null then
    -- Presente sin instructor: si lo marca un instructor (o quien marca la
    -- rutina), queda él; si es recepción, tiene que escogerlo.
    if v_role = 'instructor'
       or (new.rutina is not null and new.rutina is distinct from v_old_rutina and v_role = 'coordinador') then
      new.instructor_id := v_uid;
    elsif new.asistencia is distinct from v_old_asist or v_old_instr is not null then
      raise exception 'Escoja el instructor que atiende al cliente.';
    end if;
  end if;

  if new.instructor_id is distinct from v_old_instr then
    if new.instructor_id is not null then
      select coalesce(nullif(ur.nombre, ''), u.email::text) into v_inom
        from user_roles ur left join auth.users u on u.id = ur.id
       where ur.id = new.instructor_id
         and ur.role in ('instructor', 'coordinador')
         and (ur.sede = new.sede or new.sede = any(ur.sedes_extra));
      if v_inom is null then
        raise exception 'Ese instructor no es de la sede %.', new.sede;
      end if;
      new.instructor_nombre := v_inom;
      new.instructor_por := v_email;
      new.instructor_at := now();
    else
      new.instructor_nombre := null; new.instructor_por := null; new.instructor_at := null;
    end if;
  elsif TG_OP = 'UPDATE' then
    new.instructor_nombre := old.instructor_nombre;
    new.instructor_por    := old.instructor_por;
    new.instructor_at     := old.instructor_at;
  end if;

  -- Quién terminó la medición: solo cambia cuando cambia la rutina
  if new.rutina is distinct from v_old_rutina then
    new.rutina_por        := case when new.rutina is null then null else v_email  end;
    new.rutina_por_nombre := case when new.rutina is null then null else v_nombre end;
    new.rutina_at         := case when new.rutina is null then null else now()    end;
  elsif TG_OP = 'UPDATE' then
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

-- Mediciones viejas con la rutina marcada: el que la marcó queda como el
-- instructor que la atendió (si su cuenta es de instructor o coordinador).
alter table mediciones disable trigger mediciones_guard_trg;
update mediciones m
   set instructor_id = ur.id,
       instructor_nombre = coalesce(nullif(ur.nombre, ''), u.email::text),
       instructor_at = m.rutina_at
  from auth.users u
  join user_roles ur on ur.id = u.id
 where m.instructor_id is null
   and m.rutina is not null
   and lower(u.email) = lower(m.rutina_por)
   and ur.role in ('instructor', 'coordinador');
alter table mediciones enable trigger mediciones_guard_trg;

-- Comprobación: columnas nuevas y cuántas mediciones quedaron con instructor
select column_name from information_schema.columns
 where table_name = 'mediciones' and column_name like 'instructor%' order by 1;
select count(*) filter (where rutina is not null) as con_rutina,
       count(*) filter (where instructor_id is not null) as con_instructor
  from mediciones;
