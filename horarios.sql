-- ════════════════════════════════════════════════════════════════════════
--  HORARIOS por sede + MARCAS de recepción (disponible / sale a comer / vuelve / fin)
--
--  horarios        → una fila por persona (y por grupo de días si el horario cambia
--                    según el día): bloques de trabajo y tiempos de comida.
--  marcas_horario  → cada marca con la hora del SERVIDOR (no se puede adelantar ni
--                    atrasar desde el navegador) y una copia del horario de ese momento,
--                    para que cambiar el horario después no altere los excesos ya medidos.
--
--  Roles:
--    admin / admin_sedes / admin_g  → editan horarios, ven todo, marcas manuales y borran
--    recepcion / coordinador / admin_sucursal → ven el horario de su sede y marcan
--    instructor → solo consulta el horario de su sede
--
--  Correr UNA vez en Supabase → SQL Editor (se puede repetir sin problema).
-- ════════════════════════════════════════════════════════════════════════

create table if not exists horarios (
  id          uuid primary key default gen_random_uuid(),
  sede        text not null,
  persona     text not null,
  puesto      text not null default 'instructor' check (puesto in ('recepcion','instructor','otro')),
  user_id     uuid references auth.users(id) on delete set null,   -- su cuenta, si tiene
  dias        smallint[] not null default '{1,2,3,4,5,6}',          -- 0 = domingo … 6 = sábado
  bloques     jsonb not null default '[]',                          -- [{"ini":"05:00","fin":"10:00"}]
  comidas     jsonb not null default '[]',                          -- [{"ini":"07:15","fin":"07:30"}]
  orden       int not null default 0,
  activo      boolean not null default true,
  updated_at  timestamptz not null default now(),
  updated_by  text
);
create index if not exists horarios_sede_idx on horarios (sede);

create or replace function horarios_touch()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  new.updated_by := coalesce(auth.jwt() ->> 'email', new.updated_by);
  return new;
end; $$;
drop trigger if exists horarios_touch_trg on horarios;
create trigger horarios_touch_trg before insert or update on horarios
  for each row execute function horarios_touch();

alter table horarios enable row level security;

drop policy if exists horarios_select on horarios;
create policy horarios_select on horarios for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador','instructor')
             and (ur.sede = horarios.sede or horarios.sede = any(ur.sedes_extra))))));

drop policy if exists horarios_admin on horarios;
create policy horarios_admin on horarios for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes','admin_g')))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes','admin_g')));


create table if not exists marcas_horario (
  id             uuid primary key default gen_random_uuid(),
  sede           text not null,
  horario_id     uuid references horarios(id) on delete set null,
  persona        text not null,
  fecha          date not null,
  tipo           text not null check (tipo in ('disponible','sale_comer','vuelve_comer','fin')),
  marcado_at     timestamptz not null default now(),
  programado     jsonb,                 -- copia de bloques/comidas del horario al marcar
  manual         boolean not null default false,   -- la agregó un admin con hora a mano
  nota           text,
  registrado_por text,
  created_at     timestamptz not null default now()
);
create index if not exists marcas_horario_sede_fecha_idx on marcas_horario (sede, fecha);

-- ── Guardia del servidor ────────────────────────────────────────────────
--  1. Quien no es admin marca SIEMPRE con la hora del servidor (no hay marcas "a mano").
--  2. La fecha es la de Costa Rica según la hora de la marca.
--  3. Sede, persona y horario programado salen de la fila de horarios (no del navegador).
--  4. Orden lógico: disponible → sale a comer → vuelve → … → fin.
create or replace function marcas_horario_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_role text; v_admin boolean; v_ultimo text; h horarios%rowtype;
begin
  select role into v_role from user_roles where id = auth.uid();
  v_admin := auth.uid() is null or v_role in ('admin','admin_sedes','admin_g');   -- null = SQL Editor

  new.registrado_por := coalesce(auth.jwt() ->> 'email', new.registrado_por);
  new.created_at := now();
  if not v_admin then
    new.marcado_at := now();
    new.manual := false;
  end if;
  new.fecha := (new.marcado_at at time zone 'America/Costa_Rica')::date;

  if new.horario_id is not null then
    select * into h from horarios where id = new.horario_id;
    if found then
      new.sede := h.sede;
      new.persona := h.persona;
      new.programado := jsonb_build_object('bloques', h.bloques, 'comidas', h.comidas);
    end if;
  end if;

  if not v_admin then
    select tipo into v_ultimo from marcas_horario
     where sede = new.sede and persona = new.persona and fecha = new.fecha
     order by marcado_at desc limit 1;
    if not (
         (new.tipo = 'disponible'   and (v_ultimo is null or v_ultimo = 'fin'))
      or (new.tipo = 'sale_comer'   and v_ultimo in ('disponible','vuelve_comer'))
      or (new.tipo = 'vuelve_comer' and v_ultimo = 'sale_comer')
      or (new.tipo = 'fin'          and v_ultimo in ('disponible','vuelve_comer'))
    ) then
      raise exception 'Marca fuera de orden: % después de %', new.tipo, coalesce(v_ultimo, 'nada');
    end if;
  end if;
  return new;
end; $$;
drop trigger if exists marcas_horario_guard_trg on marcas_horario;
create trigger marcas_horario_guard_trg before insert on marcas_horario
  for each row execute function marcas_horario_guard();

alter table marcas_horario enable row level security;

drop policy if exists marcas_select on marcas_horario;
create policy marcas_select on marcas_horario for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador')
             and (ur.sede = marcas_horario.sede or marcas_horario.sede = any(ur.sedes_extra))))));

drop policy if exists marcas_insert on marcas_horario;
create policy marcas_insert on marcas_horario for insert to authenticated
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador')
             and (ur.sede = marcas_horario.sede or marcas_horario.sede = any(ur.sedes_extra))))));

-- Sin UPDATE: una marca no se edita. Se borra: admins siempre; quien la hizo, solo
-- en los primeros 5 minutos (para deshacer un toque equivocado).
drop policy if exists marcas_delete on marcas_horario;
create policy marcas_delete on marcas_horario for delete to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes','admin_g'))
         or (registrado_por = auth.jwt() ->> 'email' and created_at > now() - interval '5 minutes'));


-- ── Horario inicial de 3 Ríos (de la hoja de Excel). Solo si la sede aún no tiene horario.
--    Cada fila de la hoja se tomó como la hora completa (fila 9:00 pintada = trabaja hasta las 10:00).
--    El puesto queda "instructor": marque en el módulo quiénes son de recepción.
do $$
begin
  if not exists (select 1 from horarios where sede = '3 Ríos') then
    insert into horarios (sede, persona, orden, bloques, comidas) values
      ('3 Ríos','Andrea', 1, '[{"ini":"05:00","fin":"10:00"}]', '[{"ini":"07:15","fin":"07:30"}]'),
      ('3 Ríos','Saray',  2, '[{"ini":"10:00","fin":"15:00"}]', '[{"ini":"13:00","fin":"13:15"}]'),
      ('3 Ríos','Diana',  3, '[{"ini":"15:00","fin":"23:00"}]', '[{"ini":"18:00","fin":"18:30"}]'),
      ('3 Ríos','Mariam', 4, '[{"ini":"07:00","fin":"11:00"},{"ini":"18:00","fin":"21:00"}]',
                             '[{"ini":"07:45","fin":"08:00"},{"ini":"18:30","fin":"18:45"}]'),
      ('3 Ríos','Yetti',  5, '[]', '[]'),
      ('3 Ríos','Alonso', 6, '[{"ini":"05:00","fin":"12:00"}]', '[{"ini":"07:00","fin":"07:30"}]'),
      ('3 Ríos','Michael',7, '[{"ini":"07:00","fin":"11:00"}]', '[{"ini":"09:00","fin":"09:15"}]'),
      ('3 Ríos','Ismael', 8, '[{"ini":"12:00","fin":"21:00"}]', '[{"ini":"16:30","fin":"17:00"}]'),
      ('3 Ríos','Brandon',9, '[{"ini":"17:00","fin":"23:00"}]', '[{"ini":"20:00","fin":"20:15"}]');
  end if;
end $$;
