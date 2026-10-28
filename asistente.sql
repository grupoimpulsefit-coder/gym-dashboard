-- ════════════════════════════════════════════════════════════════════════
--  Asistente de la app — consultas que el asistente no pudo resolver
--  y trámites que requieren a Administración (anular venta, revisar SINPE…).
--  Correr UNA vez en Supabase → SQL Editor. Se puede repetir sin problema.
--
--  · La fila la crea la Edge Function `asistente` (permisos de servidor).
--  · Cada usuario ve sus propias consultas y la respuesta de Administración.
--  · Administración (admin, admin_sedes, admin_g) ve todas y las responde.
--  · `en_asistente = true`: la respuesta se le enseña al asistente, que la usa
--    en las próximas consultas (así no se vuelve a escalar la misma duda).
-- ════════════════════════════════════════════════════════════════════════

create table if not exists asistente_tickets (
  id            bigserial primary key,
  user_id       uuid not null default auth.uid(),
  usuario       text,                 -- nombre o correo de quien consultó
  rol           text,
  sede          text,
  pagina        text,                 -- módulo desde el que preguntó (/caja, /rrhh…)
  tipo          text not null,        -- duda | anular_venta | revisar_sinpe | descuadre_caja | error_app | otro
  resumen       text not null,
  detalle       text,
  estado        text not null default 'pendiente',   -- pendiente | resuelto
  respuesta     text,
  en_asistente  boolean not null default false,
  resuelto_por  text,
  resuelto_at   timestamptz,
  created_at    timestamptz not null default now()
);

create index if not exists asistente_tickets_estado on asistente_tickets (estado, created_at desc);
create index if not exists asistente_tickets_user   on asistente_tickets (user_id, created_at desc);

alter table asistente_tickets enable row level security;

drop policy if exists asistente_tickets_select on asistente_tickets;
create policy asistente_tickets_select on asistente_tickets
  for select to authenticated
  using (user_id = auth.uid() or public.mi_rol() in ('admin','admin_sedes','admin_g'));

-- Solo Administración responde / cierra (la creación la hace la Edge Function)
drop policy if exists asistente_tickets_update on asistente_tickets;
create policy asistente_tickets_update on asistente_tickets
  for update to authenticated
  using (public.mi_rol() in ('admin','admin_sedes','admin_g'))
  with check (public.mi_rol() in ('admin','admin_sedes','admin_g'));

revoke all on asistente_tickets from anon;
grant select, update on asistente_tickets to authenticated;
