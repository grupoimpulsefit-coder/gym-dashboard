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
--  nunca durante el cierre. Las agendadas en enero se reconfirman: si el
--  cliente sigue activo queda confirmada (confirmada_en); si no, cancelada.
--  Una vez agendada NO se reprograma: si el cliente no llega, la pierde
--  (solo admin puede devolverla a pendiente por un error de digitación).
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
  estado           text not null default 'pendiente',
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
    and fecha_clase not in (date '2026-12-25', date '2027-01-01'))
);

-- Reconfirmación de las agendadas en enero (también si la tabla ya existía)
alter table nat_reposiciones add column if not exists confirmada_en      timestamptz;
alter table nat_reposiciones add column if not exists confirmada_por     text;
alter table nat_reposiciones add column if not exists motivo_cancelacion text;
-- Quién agendó y cuándo (nombre del usuario en user_roles; si no tiene, su correo)
alter table nat_reposiciones add column if not exists registrado_en      timestamptz;

alter table nat_reposiciones drop constraint if exists nat_reposiciones_estado_check;
alter table nat_reposiciones add constraint nat_reposiciones_estado_check
  check (estado in ('pendiente','tomada','cancelada'));
alter table nat_reposiciones drop constraint if exists nat_repo_tomada;
alter table nat_reposiciones add constraint nat_repo_tomada check (
  (estado = 'pendiente' and fecha_reposicion is null) or
  (estado in ('tomada','cancelada') and fecha_reposicion between date '2026-12-01' and date '2027-01-31'
                                    and fecha_reposicion not between date '2026-12-24' and date '2027-01-03'));

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

-- Agendar / registrar, reconfirmar, cancelar o deshacer: admin, admin_sedes y recepción/coordinación
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
declare
  quien text := coalesce((select nullif(btrim(ur.nombre), '') from user_roles ur where ur.id = auth.uid()),
                         auth.jwt() ->> 'email');
begin
  if tg_op = 'UPDATE' then
    new.cliente := old.cliente;  new.cliente_norm := old.cliente_norm;
    new.fecha_clase := old.fecha_clase;  new.dia := old.dia;
    new.hora := old.hora;  new.actividad := old.actividad;
    new.created_at := old.created_at;
    -- Una reposición agendada no se reprograma: si el cliente no llega, la pierde.
    -- Solo admin / admin_sedes pueden devolverla a pendiente o cambiarle la fecha
    -- (para corregir errores de digitación).
    if old.estado <> 'pendiente'
       and (new.estado = 'pendiente' or new.fecha_reposicion is distinct from old.fecha_reposicion
            or (old.estado = 'cancelada' and new.estado <> 'cancelada'))
       and not exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes')) then
      raise exception 'Una reposición agendada no se cambia de fecha; si el cliente no llega, la pierde.';
    end if;
    if new.estado = 'pendiente' then
      new.fecha_reposicion := null;  new.hora_reposicion := null;  new.registrado_por := null;  new.registrado_en := null;
      new.confirmada_en := null;  new.confirmada_por := null;  new.motivo_cancelacion := null;
    elsif old.estado = 'pendiente' then          -- se acaba de agendar: queda quién y cuándo
      new.registrado_por := coalesce(quien, new.registrado_por);
      new.registrado_en  := now();
    else                                          -- no se puede cambiar quién agendó
      new.registrado_por := old.registrado_por;
      new.registrado_en  := old.registrado_en;
    end if;
    if new.estado = 'cancelada' then new.confirmada_en := null; end if;
    if new.confirmada_en is distinct from old.confirmada_en or new.estado is distinct from old.estado then
      new.confirmada_por := case when new.confirmada_en is null and new.estado <> 'cancelada' then null
                                 else coalesce(quien, new.confirmada_por) end;
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

-- ══════════════════════════════════════════════════════════════════════════
--  PAGOS DE NATACIÓN (Ventas por Producto) para el cálculo de reposiciones
--  Así el vencimiento no depende del informe de usuarios: admin sube el
--  reporte "Ventas por Producto" en la pantalla de reposiciones, se guardan
--  aquí las mensualidades de natación y cada una extiende el plan un mes.
-- ══════════════════════════════════════════════════════════════════════════
create table if not exists nat_repo_pagos (
  id           bigserial primary key,
  cliente      text not null,
  cliente_norm text not null,
  fecha        date not null,
  producto     text not null,
  total        numeric,
  subido_por   text,
  created_at   timestamptz not null default now(),
  unique (cliente_norm, fecha, producto)
);
alter table nat_repo_pagos enable row level security;

drop policy if exists nat_repo_pagos_select on nat_repo_pagos;
create policy nat_repo_pagos_select on nat_repo_pagos
  for select to authenticated using (true);

drop policy if exists nat_repo_pagos_insert on nat_repo_pagos;
create policy nat_repo_pagos_insert on nat_repo_pagos
  for insert to authenticated
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
                      and ur.role in ('admin','admin_sedes')));

create or replace function nat_repo_pagos_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.subido_por := coalesce(auth.jwt() ->> 'email', new.subido_por);
  new.created_at := now();
  return new;
end;
$$;
drop trigger if exists nat_repo_pagos_guard_trg on nat_repo_pagos;
create trigger nat_repo_pagos_guard_trg
  before insert on nat_repo_pagos
  for each row execute function nat_repo_pagos_guard();

-- Comprobación: deberían aparecer 4 políticas de nat_reposiciones y 2 de nat_repo_pagos
select tablename, policyname, cmd from pg_policies where tablename in ('nat_reposiciones','nat_repo_pagos') order by 1, 2;
