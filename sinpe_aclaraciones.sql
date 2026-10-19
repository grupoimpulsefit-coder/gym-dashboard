-- ══════════════════════════════════════════════════════════════════════════
--  SINPE — aclarar el saldo pendiente de una sede (solo administradores)
--  Correr UNA vez en Supabase → SQL Editor, después de seguridad_rls.sql
--  (usa mi_rol()). Se puede repetir sin problema.
--
--  El saldo SINPE de cada sede se arrastra de cierre en cierre (el último
--  cierre final con sinpe_pendiente). Antes, para corregirlo había que editar
--  el cierre a mano en Supabase y no quedaba rastro. Ahora se hace desde caja
--  con aclarar_sinpe(), que:
--    · EXCEDENTE (saldo positivo: entró SINPE que no se facturó): se rebaja
--      con una nota que explique por qué (obligatoria).
--    · FALTANTE (saldo negativo: se facturó más SINPE del que entró): solo con
--      respaldo: los SINPE del reporte que faltaban por contar. Se registran en
--      sinpe_registrados (no se pueden volver a contar) y suben el saldo.
--    · FACTURA ANULADA O DUPLICADA (también saldo negativo): se facturó SINPE de
--      más y la factura se eliminó después. Respaldo: el Informe de Ventas de ese
--      día descargado de nuevo (la página compara el SINPE con el original) y el
--      número de la factura. Sube el saldo por la diferencia.
--    · Guarda cada aclaración en sinpe_aclaraciones: quién, cuándo, saldo antes
--      y después, monto, nota y referencias. Nadie la puede editar ni borrar
--      desde la app.
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists sinpe_aclaraciones (
  id                uuid primary key default gen_random_uuid(),
  sede              text not null,
  cierre_id         uuid references cierres_caja(id) on delete set null,
  cierre_fecha      date,
  tipo              text not null,             -- 'excedente' | 'faltante' | 'factura'
  pendiente_antes   numeric not null,
  monto             numeric not null,          -- cuánto se aclaró (siempre positivo)
  pendiente_despues numeric not null,
  nota              text not null,
  referencias       jsonb not null default '[]'::jsonb,   -- faltante: [ {referencia, monto, fecha_tx, detalle, origen} ]
  archivo           text,                      -- nombre del reporte SINPE usado como respaldo
  hecho_por         text,
  created_at        timestamptz default now()
);
create index if not exists sinpe_acl_sede_idx on sinpe_aclaraciones (sede, created_at desc);
alter table sinpe_aclaraciones drop constraint if exists sinpe_aclaraciones_tipo_check;
alter table sinpe_aclaraciones add constraint sinpe_aclaraciones_tipo_check check (tipo in ('excedente','faltante','factura'));

alter table sinpe_aclaraciones enable row level security;
drop policy if exists sinpe_acl_admin_select on sinpe_aclaraciones;
create policy sinpe_acl_admin_select on sinpe_aclaraciones
  for select to authenticated
  using (public.mi_rol() in ('admin','admin_sedes','admin_g'));
-- Sin políticas de escritura: solo aclarar_sinpe() (security definer) escribe aquí.

alter table sinpe_aclaraciones add column if not exists dias_marcados boolean not null default false;

-- ── Marcar los días que una aclaración explica ─────────────────────────────
-- El saldo se corrige en el último cierre, pero el faltante (o excedente) se
-- generó en días anteriores: esos cierres siguen mostrando "faltó" en el
-- historial y en la auditoría. Aquí se reparte el monto aclarado entre los
-- días del tramo actual (desde el último día que arrancó en 0) que tuvieron
-- ese tipo de diferencia, del más viejo al más nuevo (o primero el día
-- indicado), y se guarda en su sinpe_reporte: aclarado (monto) y aclarado_detalle.
create or replace function public.sinpe_marcar_dias(p_cierre uuid, p_tipo text, p_monto numeric,
                                                    p_info jsonb, p_preferido uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_last  cierres_caja%rowtype;
  v_signo int := case when p_tipo = 'excedente' then 1 else -1 end;
  v_rest  numeric := round(coalesce(p_monto, 0));
  v_ids   uuid[] := '{}';
  v_id    uuid;
  v_x     uuid;
  v_sr    jsonb;
  v_delta numeric;
  v_ya    numeric;
  v_m     numeric;
  r       record;
begin
  select * into v_last from cierres_caja where id = p_cierre;
  if not found or v_rest <= 0 then return; end if;
  -- Tramo: del cierre hacia atrás mientras el día haya arrancado con saldo del mismo signo
  for r in select id, sinpe_reporte from cierres_caja
            where sede = v_last.sede and estado = 'final' and sinpe_reporte is not null
              and (fecha < v_last.fecha or (fecha = v_last.fecha and created_at <= v_last.created_at))
            order by fecha desc, created_at desc limit 60 loop
    v_ids := array_prepend(r.id, v_ids);     -- queda del más viejo al más nuevo
    exit when sign(coalesce((r.sinpe_reporte ->> 'pendPrev')::numeric, 0)) <> v_signo;
  end loop;
  -- Primero el día indicado (p. ej. el de la factura anulada); si no hay, el día cuya diferencia
  -- pendiente es exactamente el monto aclarado
  v_m := null;
  if p_preferido is not null and p_preferido = any(v_ids) then
    v_id := p_preferido;
  else
    v_id := null;
    foreach v_x in array v_ids loop
      select sinpe_reporte into v_sr from cierres_caja where id = v_x;
      v_delta := coalesce((v_sr ->> 'nuevosMonto')::numeric, 0) - coalesce((v_sr ->> 'facturado')::numeric, 0);
      if sign(v_delta) = v_signo and abs(v_delta) - coalesce((v_sr ->> 'aclarado')::numeric, 0) = v_rest then
        v_id := v_x; exit;
      end if;
    end loop;
  end if;
  if v_id is not null then v_ids := array_prepend(v_id, array_remove(v_ids, v_id)); end if;
  foreach v_id in array v_ids loop
    exit when v_rest <= 0;
    select sinpe_reporte into v_sr from cierres_caja where id = v_id;
    v_delta := coalesce((v_sr ->> 'nuevosMonto')::numeric, 0) - coalesce((v_sr ->> 'facturado')::numeric, 0);
    continue when sign(v_delta) <> v_signo;
    v_ya := coalesce((v_sr ->> 'aclarado')::numeric, 0);
    v_m := least(v_rest, abs(v_delta) - v_ya);
    continue when v_m <= 0;
    update cierres_caja
       set sinpe_reporte = coalesce(sinpe_reporte, '{}'::jsonb)
             || jsonb_build_object('aclarado', v_ya + v_m,
                                   'aclarado_detalle', coalesce(sinpe_reporte -> 'aclarado_detalle', '[]'::jsonb)
                                                       || jsonb_build_array(p_info || jsonb_build_object('monto', v_m)))
     where id = v_id;
    v_rest := v_rest - v_m;
  end loop;
end;
$$;
revoke all on function public.sinpe_marcar_dias(uuid, text, numeric, jsonb, uuid) from public;

-- ── Aclarar el saldo de una sede ───────────────────────────────────────────
-- p_tipo 'excedente': p_monto (0 < monto ≤ saldo) y p_nota.
-- p_tipo 'faltante':  p_refs con los SINPE del reporte que faltaban; el monto es su suma.
-- p_tipo 'factura':   factura anulada/duplicada: p_monto (≤ faltante), p_refs [{factura, fecha, cliente, monto}].
create or replace function public.aclarar_sinpe(p_sede text, p_tipo text, p_monto numeric,
                                                p_nota text, p_refs jsonb default '[]'::jsonb, p_archivo text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_email  text := coalesce(auth.jwt() ->> 'email', '(directo en base de datos)');
  v_c      cierres_caja%rowtype;
  v_antes  numeric;
  v_monto  numeric := 0;
  v_desp   numeric;
  v_r      jsonb;
  v_ref    text;
  v_refs   jsonb := '[]'::jsonb;
  v_acl    jsonb;
begin
  if public.mi_rol() not in ('admin','admin_sedes','admin_g') then
    raise exception 'Solo un administrador puede aclarar el saldo SINPE.' using errcode = '42501';
  end if;
  if p_tipo not in ('excedente','faltante','factura') then raise exception 'Tipo de aclaración inválido.'; end if;
  if length(btrim(coalesce(p_nota, ''))) < 8 then
    raise exception 'Escriba una nota que explique la aclaración (al menos 8 caracteres).';
  end if;

  -- El saldo vigente es el del último cierre con pendiente de la sede: ahí se aclara
  select * into v_c from cierres_caja
   where sede = p_sede and sinpe_pendiente is not null
   order by fecha desc, created_at desc limit 1 for update;
  if not found then raise exception 'La sede % no tiene saldo SINPE registrado.', p_sede; end if;
  v_antes := round(v_c.sinpe_pendiente);

  if p_tipo = 'excedente' then
    if v_antes <= 0 then raise exception 'La sede no tiene excedente de SINPE (saldo %).', v_antes; end if;
    v_monto := round(coalesce(p_monto, 0));
    if v_monto <= 0 or v_monto > v_antes then
      raise exception 'El monto a aclarar debe estar entre 1 y el excedente (%).', v_antes;
    end if;
    v_desp := v_antes - v_monto;
  elsif p_tipo = 'factura' then
    if v_antes >= 0 then raise exception 'La sede no tiene faltante de SINPE (saldo %).', v_antes; end if;
    v_monto := round(coalesce(p_monto, 0));
    if v_monto <= 0 or v_monto > -v_antes then
      raise exception 'El monto a aclarar debe estar entre 1 y el faltante (%).', -v_antes;
    end if;
    if jsonb_typeof(p_refs) <> 'array' or jsonb_array_length(p_refs) = 0
       or btrim(coalesce(p_refs -> 0 ->> 'factura', '')) = '' then
      raise exception 'Indique el número de la factura anulada o duplicada.';
    end if;
    v_refs := p_refs;
    v_desp := v_antes + v_monto;
  else
    if v_antes >= 0 then raise exception 'La sede no tiene faltante de SINPE (saldo %).', v_antes; end if;
    if jsonb_typeof(p_refs) <> 'array' or jsonb_array_length(p_refs) = 0 then
      raise exception 'Para aclarar un faltante cargue el reporte y elija los SINPE que faltaban por contar.';
    end if;
    for v_r in select * from jsonb_array_elements(p_refs) loop
      v_ref := btrim(coalesce(v_r ->> 'referencia', ''));
      if v_ref = '' then raise exception 'Hay un SINPE sin referencia.'; end if;
      if exists (select 1 from sinpe_registrados where sede = p_sede and referencia = v_ref) then
        raise exception 'El SINPE con referencia % ya estaba contado: no explica el faltante.', v_ref;
      end if;
      insert into sinpe_registrados (sede, referencia, monto, fecha_tx, detalle, cierre_id, created_by)
      values (p_sede, v_ref, round(coalesce((v_r ->> 'monto')::numeric, 0)), nullif(v_r ->> 'fecha_tx', ''),
              left(coalesce(v_r ->> 'detalle', '') || ' [aclaración de faltante]', 300), v_c.id, v_email);
      v_monto := v_monto + round(coalesce((v_r ->> 'monto')::numeric, 0));
      v_refs := v_refs || jsonb_build_array(jsonb_build_object('referencia', v_ref,
                  'monto', round(coalesce((v_r ->> 'monto')::numeric, 0)), 'fecha_tx', v_r ->> 'fecha_tx',
                  'detalle', v_r ->> 'detalle', 'origen', v_r ->> 'origen'));
    end loop;
    if v_monto <= 0 then raise exception 'Los SINPE elegidos no suman nada.'; end if;
    v_desp := v_antes + v_monto;
  end if;

  insert into sinpe_aclaraciones (sede, cierre_id, cierre_fecha, tipo, pendiente_antes, monto, pendiente_despues,
                                  nota, referencias, archivo, hecho_por, dias_marcados)
  values (p_sede, v_c.id, v_c.fecha, p_tipo, v_antes, v_monto, v_desp, btrim(p_nota), v_refs, p_archivo, v_email, true);

  -- El cierre queda con el saldo nuevo y la aclaración a la vista en su resumen SINPE
  v_acl := jsonb_build_object('tipo', p_tipo, 'antes', v_antes, 'monto', v_monto, 'despues', v_desp,
                              'nota', btrim(p_nota), 'por', v_email, 'at', now(), 'refs', jsonb_array_length(v_refs));
  update cierres_caja
     set sinpe_pendiente = v_desp,
         sinpe_reporte = jsonb_set(
           coalesce(sinpe_reporte, '{}'::jsonb)
             || jsonb_build_object('aclaraciones', coalesce(sinpe_reporte -> 'aclaraciones', '[]'::jsonb) || jsonb_build_array(v_acl)),
           '{pendAfter}', to_jsonb(v_desp))
   where id = v_c.id;

  -- Los días que generaron la diferencia quedan marcados como aclarados
  perform public.sinpe_marcar_dias(v_c.id, p_tipo, v_monto,
    jsonb_build_object('tipo', p_tipo, 'nota', btrim(p_nota), 'por', v_email, 'at', now()),
    case when p_tipo = 'factura' then nullif(p_refs -> 0 ->> 'dia_id', '')::uuid end);

  return jsonb_build_object('sede', p_sede, 'cierre_fecha', v_c.fecha, 'antes', v_antes, 'monto', v_monto, 'despues', v_desp);
end;
$$;
revoke all on function public.aclarar_sinpe(text, text, numeric, text, jsonb, text) from public;
grant execute on function public.aclarar_sinpe(text, text, numeric, text, jsonb, text) to authenticated;

-- ── Aclaraciones hechas antes de este cambio: marcar sus días una sola vez ──
do $$
declare a record; v_pref uuid;
begin
  for a in select * from sinpe_aclaraciones where not dias_marcados and cierre_id is not null order by created_at loop
    v_pref := null;
    if a.tipo = 'factura' and (a.referencias -> 0 ->> 'fecha') is not null then
      select id into v_pref from cierres_caja
       where sede = a.sede and estado = 'final' and fecha = (a.referencias -> 0 ->> 'fecha')::date
       order by created_at desc limit 1;
    end if;
    perform public.sinpe_marcar_dias(a.cierre_id, a.tipo, a.monto,
      jsonb_build_object('tipo', a.tipo, 'nota', a.nota, 'por', a.hecho_por, 'at', a.created_at), v_pref);
    update sinpe_aclaraciones set dias_marcados = true where id = a.id;
  end loop;
end $$;

-- Comprobación: saldo vigente de cada sede
select distinct on (sede) sede, fecha, turno_num, sinpe_pendiente
from cierres_caja
where sinpe_pendiente is not null
order by sede, fecha desc, created_at desc;
