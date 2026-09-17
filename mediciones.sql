-- ════════════════════════════════════════════════════════════════════════
--  Módulo de MEDICIONES — agenda semanal por sede, citas cada 15 minutos
--  Horario: mañana 08:00 → 10:45 (última) · tarde 17:00 → 19:45 (última)
--
--  Roles:
--    recepcion / admin_sucursal → agendan, editan y borran citas de SU sede
--    instructor (rol nuevo)     → SOLO puede marcar la rutina (completa/incompleta)
--    admin / admin_sedes / admin_g → todo, en todas las sedes
--
--  Correr UNA vez en Supabase → SQL Editor.
-- ════════════════════════════════════════════════════════════════════════

create table if not exists mediciones (
  id                   uuid primary key default gen_random_uuid(),
  sede                 text not null,
  fecha                date not null,
  hora                 time not null,                -- 08:00, 08:15, … 19:45
  nombre               text not null,
  telefono             text,
  pin                  text,
  rutina               text check (rutina in ('completa','incompleta')),   -- null = pendiente
  rutina_por           text,                         -- correo del instructor que la marcó
  rutina_at            timestamptz,
  agendado_por         text,                         -- correo de quien agendó (lo pone el servidor)
  agendado_por_nombre  text,                         -- nombre para mostrar
  nota                 text,
  created_at           timestamptz default now(),
  updated_at           timestamptz default now()
);

-- Un solo cliente por espacio (sede + día + hora): evita doble reserva
create unique index if not exists mediciones_slot_idx on mediciones (sede, fecha, hora);
create index if not exists mediciones_sede_fecha_idx on mediciones (sede, fecha);

-- ── Guardia del servidor ────────────────────────────────────────────────
--  1. "Agendado por" se sella con el correo de quien inserta (no se puede falsear).
--  2. El INSTRUCTOR solo puede cambiar la rutina: cualquier otro campo se revierte.
--  3. Al cambiar la rutina se registra quién y cuándo.
create or replace function mediciones_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_role text; v_email text;
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
    end if;
    return new;
  end if;

  -- UPDATE
  if v_role = 'instructor' then
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
  end if;

  if new.rutina is distinct from old.rutina then
    new.rutina_por := v_email;
    new.rutina_at := case when new.rutina is null then null else now() end;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists mediciones_guard_trg on mediciones;
create trigger mediciones_guard_trg
  before insert or update on mediciones
  for each row execute function mediciones_guard();

-- ── RLS ─────────────────────────────────────────────────────────────────
alter table mediciones enable row level security;

-- Ver: admins todas las sedes; recepción / admin de sucursal / instructor, su sede (o sedes_extra)
drop policy if exists mediciones_select on mediciones;
create policy mediciones_select on mediciones
  for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador','instructor')
             and (ur.sede = mediciones.sede or mediciones.sede = any(ur.sedes_extra))))));

-- Agendar: admins + recepción + admin de sucursal (el instructor NO agenda)
drop policy if exists mediciones_insert on mediciones;
create policy mediciones_insert on mediciones
  for insert to authenticated
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador')
             and (ur.sede = mediciones.sede or mediciones.sede = any(ur.sedes_extra))))));

-- Editar: también el instructor, pero el trigger lo limita a la rutina
drop policy if exists mediciones_update on mediciones;
create policy mediciones_update on mediciones
  for update to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador','instructor')
             and (ur.sede = mediciones.sede or mediciones.sede = any(ur.sedes_extra))))))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador','instructor')
             and (ur.sede = mediciones.sede or mediciones.sede = any(ur.sedes_extra))))));

-- Borrar: admins + recepción + admin de sucursal (el instructor NO borra)
drop policy if exists mediciones_delete on mediciones;
create policy mediciones_delete on mediciones
  for delete to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador')
             and (ur.sede = mediciones.sede or mediciones.sede = any(ur.sedes_extra))))));
