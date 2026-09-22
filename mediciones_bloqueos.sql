-- ════════════════════════════════════════════════════════════════════════
--  MEDICIONES — bloqueo de espacios
--  Correr UNA vez en Supabase → SQL Editor. Se puede repetir sin problema.
--
--  Dos formas de bloquear un espacio de la agenda:
--    'permanente' → todas las semanas ese día y esa hora (ej. todos los martes
--                   a las 5:00 p. m. el salón está ocupado por otra clase).
--    'unico'      → solo una fecha concreta (ej. el 30 de setiembre hay feriado).
--
--  dia_semana usa la misma numeración que la app: 0 = lunes … 4 = viernes.
--  Quien puede agendar puede bloquear. El instructor solo los ve.
-- ════════════════════════════════════════════════════════════════════════

create table if not exists mediciones_bloqueos (
  id          uuid primary key default gen_random_uuid(),
  sede        text not null,
  tipo        text not null check (tipo in ('permanente','unico')),
  dia_semana  smallint check (dia_semana between 0 and 4),  -- solo 'permanente'
  fecha       date,                                          -- solo 'unico'
  hora        time not null,                                 -- 08:00 … 19:45
  motivo      text,
  creado_por  text,                                          -- lo sella el servidor
  created_at  timestamptz default now(),
  -- Cada tipo usa su propia columna de fecha; nunca las dos ni ninguna.
  constraint mediciones_bloqueos_forma check (
    (tipo = 'permanente' and dia_semana is not null and fecha is null) or
    (tipo = 'unico'      and fecha      is not null and dia_semana is null)
  )
);

-- No repetir el mismo bloqueo
create unique index if not exists mediciones_bloq_perm_idx
  on mediciones_bloqueos (sede, dia_semana, hora) where tipo = 'permanente';
create unique index if not exists mediciones_bloq_unico_idx
  on mediciones_bloqueos (sede, fecha, hora) where tipo = 'unico';
create index if not exists mediciones_bloq_sede_idx on mediciones_bloqueos (sede);

-- ── Sellar quién lo creó (no se puede falsear desde el cliente) ──────────
create or replace function mediciones_bloqueos_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.creado_por := coalesce(nullif(new.creado_por, ''), auth.jwt() ->> 'email');
  return new;
end;
$$;
drop trigger if exists mediciones_bloqueos_guard_trg on mediciones_bloqueos;
create trigger mediciones_bloqueos_guard_trg
  before insert on mediciones_bloqueos
  for each row execute function mediciones_bloqueos_guard();

-- ── No se puede agendar sobre un espacio bloqueado ───────────────────────
--  La app ya lo evita, pero esto cierra la carrera entre dos personas
--  (una bloquea mientras la otra está agendando).
create or replace function mediciones_slot_libre()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_dow smallint; v_motivo text;
begin
  v_dow := extract(isodow from new.fecha)::int - 1;   -- lunes = 0
  select coalesce(b.motivo, '') into v_motivo
    from mediciones_bloqueos b
   where b.sede = new.sede
     and b.hora = new.hora
     and ( (b.tipo = 'permanente' and b.dia_semana = v_dow)
        or (b.tipo = 'unico'      and b.fecha      = new.fecha) )
   limit 1;
  if found then
    raise exception 'bloqueado: el espacio del % a las % no está disponible%',
      to_char(new.fecha, 'DD/MM/YYYY'), to_char(new.hora, 'HH24:MI'),
      case when v_motivo <> '' then ' (' || v_motivo || ')' else '' end
      using errcode = '23514';
  end if;
  return new;
end;
$$;
drop trigger if exists mediciones_slot_libre_trg on mediciones;
create trigger mediciones_slot_libre_trg
  before insert on mediciones
  for each row execute function mediciones_slot_libre();

-- ── RLS ─────────────────────────────────────────────────────────────────
alter table mediciones_bloqueos enable row level security;

-- Ver: los mismos que ven la agenda (el instructor incluido)
drop policy if exists mediciones_bloq_select on mediciones_bloqueos;
create policy mediciones_bloq_select on mediciones_bloqueos
  for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador','instructor')
             and (ur.sede = mediciones_bloqueos.sede or mediciones_bloqueos.sede = any(ur.sedes_extra))))));

-- Bloquear: los mismos que agendan (el instructor NO)
drop policy if exists mediciones_bloq_insert on mediciones_bloqueos;
create policy mediciones_bloq_insert on mediciones_bloqueos
  for insert to authenticated
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador')
             and (ur.sede = mediciones_bloqueos.sede or mediciones_bloqueos.sede = any(ur.sedes_extra))))));

drop policy if exists mediciones_bloq_update on mediciones_bloqueos;
create policy mediciones_bloq_update on mediciones_bloqueos
  for update to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador')
             and (ur.sede = mediciones_bloqueos.sede or mediciones_bloqueos.sede = any(ur.sedes_extra))))))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador')
             and (ur.sede = mediciones_bloqueos.sede or mediciones_bloqueos.sede = any(ur.sedes_extra))))));

-- Desbloquear
drop policy if exists mediciones_bloq_delete on mediciones_bloqueos;
create policy mediciones_bloq_delete on mediciones_bloqueos
  for delete to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador')
             and (ur.sede = mediciones_bloqueos.sede or mediciones_bloqueos.sede = any(ur.sedes_extra))))));

-- Comprobación
select tipo, count(*) from mediciones_bloqueos group by tipo;
