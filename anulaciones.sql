-- ══════════════════════════════════════════════════════════════════════════
--  SOLICITUDES DE ANULACIÓN DE FACTURAS DE CAJA
--  Correr UNA vez en el SQL editor de Supabase, después de facturacion.sql.
--  Se puede repetir sin problema.
--
--  Recepción (o admin_sucursal) no puede anular facturas: pide la anulación con
--  un motivo. La Edge Function `asistente` (accion 'solicitar_anulacion') llama a
--  solicitar_anulacion_factura() y avisa por push a Administración y al
--  coordinador de la sede. Quien aprueba toca un botón (movil.html o caja.html):
--  resolver_anulacion_factura() anula con anular_factura_caja() (devuelve el
--  stock) y la función avisa a quien la pidió.
--  Solo se puede anular mientras el turno de la factura siga abierto; si se
--  cierra antes, la solicitud queda 'vencida' y se resuelve como descuadre.
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists anulaciones_caja (
  id             bigserial primary key,
  factura_id     uuid not null references facturas_caja(id),
  sede           text not null,
  fecha          date not null,                 -- día de la factura
  numero         int  not null,
  total          numeric not null,
  motivo         text not null,
  estado         text not null default 'pendiente'
                 check (estado in ('pendiente','aprobada','rechazada','vencida')),
  solicitado_por uuid default auth.uid(),
  solicitante    text,                          -- nombre o correo de quien la pidió
  resuelto_por   text,
  resuelto_at    timestamptz,
  nota           text,                          -- por qué se rechazó o venció
  created_at     timestamptz not null default now()
);
-- Una sola solicitud pendiente por factura
create unique index if not exists anulaciones_caja_pend on anulaciones_caja (factura_id) where estado = 'pendiente';
create index if not exists anulaciones_caja_sede_fecha on anulaciones_caja (sede, fecha);

alter table anulaciones_caja enable row level security;

-- Ver: Administración todas; el resto, las de su sede (principal o sedes_extra)
drop policy if exists anulaciones_caja_select on anulaciones_caja;
create policy anulaciones_caja_select on anulaciones_caja
  for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
          and (ur.role in ('admin','admin_sedes','admin_g')
               or (ur.role in ('recepcion','admin_sucursal','coordinador')
                   and (ur.sede = anulaciones_caja.sede or anulaciones_caja.sede = any(ur.sedes_extra))))));

-- Nadie escribe directo: solo las dos funciones de abajo
revoke all on anulaciones_caja from anon;
revoke insert, update, delete on anulaciones_caja from authenticated;
grant select on anulaciones_caja to authenticated;

-- ── Pedir la anulación ──────────────────────────────────────────────────────
create or replace function solicitar_anulacion_factura(p_factura uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_rol    text := public.mi_rol();
  v_ur     user_roles%rowtype;
  v_f      facturas_caja%rowtype;
  v_c      cierres_caja%rowtype;
  v_motivo text := nullif(btrim(coalesce(p_motivo, '')), '');
  v_quien  text;
  v_id     bigint;
begin
  select * into v_ur from user_roles where id = auth.uid();
  if v_rol not in ('admin','admin_sedes','admin_g','recepcion','admin_sucursal','coordinador') then
    raise exception 'Sin permiso para pedir anulaciones.' using errcode = '42501';
  end if;
  if v_motivo is null then raise exception 'Indique el motivo de la anulación.'; end if;

  select * into v_f from facturas_caja where id = p_factura for update;
  if not found then raise exception 'La factura no existe.'; end if;
  if v_rol not in ('admin','admin_sedes','admin_g')
     and v_f.sede is distinct from v_ur.sede and not (v_f.sede = any(coalesce(v_ur.sedes_extra, '{}'))) then
    raise exception 'Solo puede pedir anulaciones de facturas de su sede.' using errcode = '42501';
  end if;
  if v_f.estado = 'anulada' then raise exception 'La factura ya está anulada.'; end if;

  select * into v_c from cierres_caja where id = v_f.cierre_id;
  if not found or v_c.estado <> 'abierto' then
    raise exception 'El turno de esta factura ya se cerró: no se puede anular. Repórtelo a Administración como descuadre.';
  end if;
  if exists (select 1 from anulaciones_caja where factura_id = p_factura and estado = 'pendiente') then
    raise exception 'Ya hay una solicitud pendiente para la factura #%.', v_f.numero;
  end if;

  v_quien := coalesce(nullif(v_ur.nombre, ''), auth.jwt() ->> 'email');
  insert into anulaciones_caja (factura_id, sede, fecha, numero, total, motivo, solicitado_por, solicitante)
  values (v_f.id, v_f.sede, v_f.fecha, v_f.numero, v_f.total, left(v_motivo, 300), auth.uid(), v_quien)
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'factura_id', v_f.id, 'sede', v_f.sede, 'fecha', v_f.fecha,
    'numero', v_f.numero, 'total', v_f.total, 'metodo', v_f.metodo, 'tipo', v_f.tipo,
    'motivo', left(v_motivo, 300), 'solicitante', v_quien);
end;
$$;
revoke all on function solicitar_anulacion_factura(uuid, text) from public;
grant execute on function solicitar_anulacion_factura(uuid, text) to authenticated;

-- ── Aprobar (anula) o rechazar: Administración o el coordinador de la sede ──
create or replace function resolver_anulacion_factura(p_solicitud bigint, p_aprobar boolean, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_rol   text := public.mi_rol();
  v_email text := auth.jwt() ->> 'email';
  v_s     anulaciones_caja%rowtype;
  v_f     facturas_caja%rowtype;
  v_c     cierres_caja%rowtype;
  v_nota  text := nullif(btrim(coalesce(p_nota, '')), '');
  v_est   text;
begin
  select * into v_s from anulaciones_caja where id = p_solicitud for update;
  if not found then raise exception 'La solicitud no existe.'; end if;

  if not (v_rol in ('admin','admin_sedes','admin_g') or exists (
      select 1 from user_roles ur where ur.id = auth.uid() and ur.role = 'coordinador'
        and (ur.sede = v_s.sede or v_s.sede = any(ur.sedes_extra)))) then
    raise exception 'Solo un coordinador de la sede o un administrador puede aprobar anulaciones.' using errcode = '42501';
  end if;
  if v_s.estado <> 'pendiente' then
    raise exception 'Esta solicitud ya fue resuelta (%).', v_s.estado;
  end if;

  select * into v_f from facturas_caja where id = v_s.factura_id;
  select * into v_c from cierres_caja where id = v_f.cierre_id;

  if not p_aprobar then
    v_est := 'rechazada';
  elsif v_f.estado = 'anulada' then
    v_est := 'aprobada';   -- alguien la anuló directo mientras tanto
    v_nota := coalesce(v_nota, 'La factura ya estaba anulada.');
  elsif v_c.estado is distinct from 'abierto' then
    v_est := 'vencida';    -- el turno se cerró antes de aprobar: ya no se puede anular
    v_nota := 'El turno se cerró antes de aprobar: la factura ya no se puede anular. Resolver como descuadre.';
  else
    perform anular_factura_caja(v_f.id, 'Solicitud #' || v_s.id || ' (' || coalesce(v_s.solicitante, '') || '): ' || v_s.motivo);
    v_est := 'aprobada';
  end if;

  update anulaciones_caja set estado = v_est, nota = v_nota, resuelto_por = v_email, resuelto_at = now()
   where id = v_s.id;

  return jsonb_build_object('id', v_s.id, 'estado', v_est, 'nota', v_nota, 'sede', v_s.sede,
    'numero', v_s.numero, 'total', v_s.total, 'solicitado_por', v_s.solicitado_por);
end;
$$;
revoke all on function resolver_anulacion_factura(bigint, boolean, text) from public;
grant execute on function resolver_anulacion_factura(bigint, boolean, text) to authenticated;

-- Comprobación: deberían aparecer la política y las dos funciones
select policyname, cmd from pg_policies where tablename = 'anulaciones_caja';
select proname from pg_proc where proname in ('solicitar_anulacion_factura','resolver_anulacion_factura');
