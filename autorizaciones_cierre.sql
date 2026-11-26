-- ══════════════════════════════════════════════════════════════════════════
--  AUTORIZACIÓN PARA CERRAR CAJA SIN INFORME DE VENTAS AL DÍA
--  Correr UNA vez en el SQL editor de Supabase. Se puede repetir sin problema.
--
--  Un turno solo se cierra (parcial o final) con un Informe de Ventas generado
--  hace 10 minutos o menos (caja.html lee la hora del pie del Informe). Si no se
--  puede, quien cierra pide autorización con un motivo:
--    'informe_viejo' → cerrar con un Informe de más de 10 minutos
--    'sin_informe'   → cerrar sin Informe de Ventas (también permite uno viejo)
--  La Edge Function `asistente` (accion 'solicitar_autorizacion_cierre') llama a
--  solicitar_autorizacion_cierre() y avisa por push a Administración. Un admin
--  aprueba o rechaza (caja.html) con resolver_autorizacion_cierre() y la función
--  avisa a quien la pidió. La autorización vale solo para ese turno y mientras
--  siga abierto. Un administrador que cierra su propia caja no necesita pedirla.
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists autorizaciones_cierre (
  id               bigserial primary key,
  cierre_id        uuid not null references cierres_caja(id),
  sede             text not null,
  fecha            date not null,
  turno_num        int,
  tipo             text not null check (tipo in ('informe_viejo','sin_informe')),
  motivo           text not null,
  informe_generado timestamptz,                  -- hora del Informe que tenía cargado (si tenía)
  estado           text not null default 'pendiente'
                   check (estado in ('pendiente','aprobada','rechazada','vencida')),
  solicitado_por   uuid default auth.uid(),
  solicitante      text,
  resuelto_por     text,
  resuelto_at      timestamptz,
  nota             text,
  created_at       timestamptz not null default now()
);
-- Una sola solicitud pendiente por turno
create unique index if not exists autorizaciones_cierre_pend on autorizaciones_cierre (cierre_id) where estado = 'pendiente';
create index if not exists autorizaciones_cierre_estado on autorizaciones_cierre (estado, created_at);

alter table autorizaciones_cierre enable row level security;

-- Ver: Administración todas; el resto, las de su sede (principal o sedes_extra)
drop policy if exists autorizaciones_cierre_select on autorizaciones_cierre;
create policy autorizaciones_cierre_select on autorizaciones_cierre
  for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
          and (ur.role in ('admin','admin_sedes','admin_g')
               or (ur.role in ('recepcion','admin_sucursal','coordinador')
                   and (ur.sede = autorizaciones_cierre.sede or autorizaciones_cierre.sede = any(ur.sedes_extra))))));

-- Nadie escribe directo: solo las dos funciones de abajo
revoke all on autorizaciones_cierre from anon;
revoke insert, update, delete on autorizaciones_cierre from authenticated;
grant select on autorizaciones_cierre to authenticated;

-- ── Pedir la autorización ───────────────────────────────────────────────────
create or replace function solicitar_autorizacion_cierre(p_cierre uuid, p_tipo text, p_motivo text,
                                                         p_generado timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_rol    text := public.mi_rol();
  v_ur     user_roles%rowtype;
  v_c      cierres_caja%rowtype;
  v_motivo text := nullif(btrim(coalesce(p_motivo, '')), '');
  v_quien  text;
  v_id     bigint;
begin
  select * into v_ur from user_roles where id = auth.uid();
  if v_rol not in ('admin','admin_sedes','admin_g','recepcion','admin_sucursal','coordinador') then
    raise exception 'Sin permiso para pedir esta autorización.' using errcode = '42501';
  end if;
  if p_tipo not in ('informe_viejo','sin_informe') then raise exception 'Tipo de autorización inválido.'; end if;
  if v_motivo is null or length(v_motivo) < 5 then raise exception 'Indique el motivo (por qué no se puede descargar el Informe de Ventas).'; end if;

  select * into v_c from cierres_caja where id = p_cierre;
  if not found then raise exception 'El turno no existe.'; end if;
  if v_rol not in ('admin','admin_sedes','admin_g')
     and v_c.sede is distinct from v_ur.sede and not (v_c.sede = any(coalesce(v_ur.sedes_extra, '{}'))) then
    raise exception 'Solo puede pedir autorizaciones de su sede.' using errcode = '42501';
  end if;
  if v_c.estado <> 'abierto' then raise exception 'El turno ya está cerrado.'; end if;
  if exists (select 1 from autorizaciones_cierre where cierre_id = p_cierre and estado = 'pendiente') then
    raise exception 'Ya hay una solicitud pendiente para este turno: espere a que Administración la resuelva.';
  end if;

  v_quien := coalesce(nullif(v_ur.nombre, ''), auth.jwt() ->> 'email');
  insert into autorizaciones_cierre (cierre_id, sede, fecha, turno_num, tipo, motivo, informe_generado, solicitado_por, solicitante)
  values (v_c.id, v_c.sede, v_c.fecha, v_c.turno_num, p_tipo, left(v_motivo, 300), p_generado, auth.uid(), v_quien)
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'sede', v_c.sede, 'fecha', v_c.fecha, 'turno_num', v_c.turno_num,
    'tipo', p_tipo, 'motivo', left(v_motivo, 300), 'informe_generado', p_generado, 'solicitante', v_quien);
end;
$$;
revoke all on function solicitar_autorizacion_cierre(uuid, text, text, timestamptz) from public;
grant execute on function solicitar_autorizacion_cierre(uuid, text, text, timestamptz) to authenticated;

-- ── Aprobar o rechazar: solo Administración ─────────────────────────────────
create or replace function resolver_autorizacion_cierre(p_id bigint, p_aprobar boolean, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_rol   text := public.mi_rol();
  v_email text := auth.jwt() ->> 'email';
  v_a     autorizaciones_cierre%rowtype;
  v_c     cierres_caja%rowtype;
  v_nota  text := nullif(btrim(coalesce(p_nota, '')), '');
  v_est   text;
begin
  if v_rol not in ('admin','admin_sedes','admin_g') then
    raise exception 'Solo un administrador puede autorizar el cierre.' using errcode = '42501';
  end if;
  select * into v_a from autorizaciones_cierre where id = p_id for update;
  if not found then raise exception 'La solicitud no existe.'; end if;
  if v_a.estado <> 'pendiente' then raise exception 'Esta solicitud ya fue resuelta (%).', v_a.estado; end if;

  select * into v_c from cierres_caja where id = v_a.cierre_id;
  if not p_aprobar then
    v_est := 'rechazada';
  elsif v_c.estado is distinct from 'abierto' then
    v_est := 'vencida';
    v_nota := 'El turno ya se había cerrado.';
  else
    v_est := 'aprobada';
  end if;

  update autorizaciones_cierre set estado = v_est, nota = v_nota, resuelto_por = v_email, resuelto_at = now()
   where id = v_a.id;

  return jsonb_build_object('id', v_a.id, 'estado', v_est, 'nota', v_nota, 'sede', v_a.sede, 'fecha', v_a.fecha,
    'turno_num', v_a.turno_num, 'tipo', v_a.tipo, 'solicitado_por', v_a.solicitado_por);
end;
$$;
revoke all on function resolver_autorizacion_cierre(bigint, boolean, text) from public;
grant execute on function resolver_autorizacion_cierre(bigint, boolean, text) to authenticated;

-- Comprobación: deberían aparecer la política y las dos funciones
select policyname, cmd from pg_policies where tablename = 'autorizaciones_cierre';
select proname from pg_proc where proname in ('solicitar_autorizacion_cierre','resolver_autorizacion_cierre');
