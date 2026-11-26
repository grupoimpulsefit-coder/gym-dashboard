-- ══════════════════════════════════════════════════════════════════════════
--  REPOSICIONES DE NATACIÓN — cierre de piscina de fin de año
--  Correr UNA vez en el SQL editor de Supabase. Se puede repetir sin problema.
--
--  La piscina cierra del 24/12/2026 al 03/01/2027. Las clases de esos días se
--  reponen, menos las del 25/12 y el 01/01. nat.html (pestaña "Reposiciones")
--  calcula cuántas le tocan a cada cliente cruzando el calendario de
--  reservaciones con el informe de usuarios (activo y con el plan vigente en
--  la fecha de la clase) y guarda aquí una fila por clase a reponer.
--
--  Cada fila se marca como tomada con la fecha en que el cliente la repuso:
--  se puede adelantar en diciembre (desde el 01/12) o tomar hasta el 31/01,
--  nunca durante el cierre.
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists nat_reposiciones (
  id               bigserial primary key,
  cliente          text not null,
  cliente_norm     text not null,
  pin              text,
  plan             text,
  expira           date,
  fecha_clase      date not null,          -- día cerrado que se repone
  dia              text not null,
  hora             text not null,
  actividad        text not null,
  estado           text not null default 'pendiente' check (estado in ('pendiente','tomada')),
  fecha_reposicion date,
  hora_reposicion  text,
  nota             text,
  registrado_por   text,
  created_at       timestamptz not null default now(),
  updated_by       text,
  updated_at       timestamptz not null default now(),
  unique (cliente_norm, fecha_clase, hora, actividad),
  constraint nat_repo_fecha_clase check (
    fecha_clase between date '2026-12-24' and date '2027-01-03'
    and fecha_clase not in (date '2026-12-25', date '2027-01-01')),
  constraint nat_repo_tomada check (
    (estado = 'pendiente' and fecha_reposicion is null) or
    (estado = 'tomada' and fecha_reposicion between date '2026-12-01' and date '2027-01-31'
                       and fecha_reposicion not between date '2026-12-24' and date '2027-01-03'))
);

create index if not exists nat_reposiciones_cliente_idx on nat_reposiciones (cliente_norm);

alter table nat_reposiciones enable row level security;

-- Ver: cualquier usuario que entra a nat.html
drop policy if exists nat_repo_select on nat_reposiciones;
create policy nat_repo_select on nat_reposiciones
  for select to authenticated using (true);

-- Generar / recalcular (insertar y borrar pendientes): admin y admin_sedes
drop policy if exists nat_repo_insert on nat_reposiciones;
create policy nat_repo_insert on nat_reposiciones
  for insert to authenticated
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
                      and ur.role in ('admin','admin_sedes')));

drop policy if exists nat_repo_delete on nat_reposiciones;
create policy nat_repo_delete on nat_reposiciones
  for delete to authenticated
  using (estado = 'pendiente' and exists (select 1 from user_roles ur where ur.id = auth.uid()
                      and ur.role in ('admin','admin_sedes')));

-- Registrar que se tomó (o deshacerlo): admin, admin_sedes y recepción/coordinación
drop policy if exists nat_repo_update on nat_reposiciones;
create policy nat_repo_update on nat_reposiciones
  for update to authenticated
  using      (exists (select 1 from user_roles ur where ur.id = auth.uid()
                      and ur.role in ('admin','admin_sedes','recepcion','coordinador','admin_sucursal')))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
                      and ur.role in ('admin','admin_sedes','recepcion','coordinador','admin_sucursal')));

-- Sella quién y cuándo; al actualizar solo se puede cambiar el registro de la toma
create or replace function nat_reposiciones_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    new.cliente := old.cliente;  new.cliente_norm := old.cliente_norm;
    new.fecha_clase := old.fecha_clase;  new.dia := old.dia;
    new.hora := old.hora;  new.actividad := old.actividad;
    new.created_at := old.created_at;
    if new.estado = 'tomada' and old.estado = 'pendiente' then
      new.registrado_por := coalesce(auth.jwt() ->> 'email', new.registrado_por);
    elsif new.estado = 'pendiente' then
      new.fecha_reposicion := null;  new.hora_reposicion := null;  new.registrado_por := null;
    end if;
  end if;
  new.updated_by := coalesce(auth.jwt() ->> 'email', new.updated_by);
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists nat_reposiciones_guard_trg on nat_reposiciones;
create trigger nat_reposiciones_guard_trg
  before insert or update on nat_reposiciones
  for each row execute function nat_reposiciones_guard();

-- Comprobación: deberían aparecer las 4 políticas
select policyname, cmd from pg_policies where tablename = 'nat_reposiciones' order by policyname;
