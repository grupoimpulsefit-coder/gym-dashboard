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


-- ── Detalles agregados después (2026-10-28) ────────────────────────────────
--  Quien abrió la consulta le agrega datos mientras siga pendiente, en vez de
--  crear otra. Lo usan Chloe (Edge Function) y el botón "Agregar detalle".
alter table asistente_tickets add column if not exists agregados      jsonb not null default '[]';   -- [ { texto, at } ]
alter table asistente_tickets add column if not exists actualizado_at timestamptz;

create or replace function asistente_agregar_detalle(p_ticket bigint, p_texto text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  t     asistente_tickets%rowtype;
  v_txt text := left(btrim(coalesce(p_texto, '')), 2000);
begin
  if v_txt = '' then raise exception 'Escriba el detalle que quiere agregar.'; end if;
  select * into t from asistente_tickets where id = p_ticket for update;
  if not found or t.user_id is distinct from auth.uid() then
    raise exception 'La consulta #% no es suya.', p_ticket using errcode = '42501';
  end if;
  if t.estado <> 'pendiente' then
    raise exception 'La consulta #% ya fue respondida. Si falta algo, escríbalo en el chat y se abre una nueva.', t.id;
  end if;
  update asistente_tickets
     set agregados = coalesce(agregados, '[]'::jsonb) || jsonb_build_array(jsonb_build_object('texto', v_txt, 'at', now())),
         actualizado_at = now()
   where id = t.id;
  return jsonb_build_object('id', t.id, 'resumen', t.resumen, 'usuario', t.usuario, 'sede', t.sede);
end; $$;
revoke all on function asistente_agregar_detalle(bigint, text) from public;
grant execute on function asistente_agregar_detalle(bigint, text) to authenticated;


-- ── Notificaciones push de la app móvil (2026-10-28) ───────────────────────
--  Un teléfono por fila. Se activa en la app móvil → Cuenta. La Edge Function
--  avisa a Administración cuando se crea una consulta o se le agregan datos.
--  Sin políticas: solo se escribe con guardar_push/quitar_push y lo lee el servidor.
create table if not exists push_suscripciones (
  endpoint    text primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  p256dh      text not null,
  auth        text not null,
  user_agent  text,
  created_at  timestamptz not null default now()
);
alter table push_suscripciones enable row level security;
revoke all on push_suscripciones from anon, authenticated;

create or replace function guardar_push(p_endpoint text, p_p256dh text, p_auth text, p_ua text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Inicie sesión.' using errcode = '42501'; end if;
  if coalesce(p_endpoint, '') !~ '^https://' or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then
    raise exception 'Suscripción inválida.';
  end if;
  insert into push_suscripciones (endpoint, user_id, p256dh, auth, user_agent)
  values (p_endpoint, auth.uid(), p_p256dh, p_auth, left(p_ua, 300))
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
        user_agent = excluded.user_agent, created_at = now();
end; $$;

create or replace function quitar_push(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from push_suscripciones where endpoint = p_endpoint and user_id = auth.uid();
$$;

revoke all on function guardar_push(text, text, text, text) from public;
revoke all on function quitar_push(text) from public;
grant execute on function guardar_push(text, text, text, text) to authenticated;
grant execute on function quitar_push(text) to authenticated;


-- ── Conocimiento que Administración le enseña a Chloe desde el chat (2026-10-29) ──
--  Un admin le escribe a Chloe "agregá a tu conocimiento que…" y la Edge Function
--  guarda la nota aquí (permisos de servidor). Chloe la usa en todas las consultas
--  siguientes, igual que el manual. Administración la ve en la pestaña
--  "Conocimiento" del chat y la puede quitar (activo = false) si quedó vieja.
create table if not exists asistente_conocimiento (
  id          bigserial primary key,
  tema        text not null,
  contenido   text not null,
  activo      boolean not null default true,
  creado_por  uuid default auth.uid(),
  autor       text,                 -- nombre o correo de quien lo enseñó
  quitado_por uuid,
  quitado_at  timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists asistente_conocimiento_activo on asistente_conocimiento (activo, created_at desc);

alter table asistente_conocimiento enable row level security;

drop policy if exists asistente_conocimiento_select on asistente_conocimiento;
create policy asistente_conocimiento_select on asistente_conocimiento
  for select to authenticated
  using (public.mi_rol() in ('admin','admin_sedes','admin_g'));

drop policy if exists asistente_conocimiento_update on asistente_conocimiento;
create policy asistente_conocimiento_update on asistente_conocimiento
  for update to authenticated
  using (public.mi_rol() in ('admin','admin_sedes','admin_g'))
  with check (public.mi_rol() in ('admin','admin_sedes','admin_g'));

revoke all on asistente_conocimiento from anon;
grant select, update on asistente_conocimiento to authenticated;
