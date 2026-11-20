-- ══════════════════════════════════════════════════════════════════════════
--  ANULAR UNA VENTA DE CAJA DE UN TURNO YA CERRADO (solo Administración)
--  Correr UNA vez en Supabase → SQL Editor, después de facturacion.sql,
--  anulaciones.sql y sinpe_aclaraciones.sql. Se puede repetir sin problema.
--
--  Antes, una factura de caja (minita, eventos) solo se podía anular con el
--  turno abierto. Ahora un administrador (admin, admin_sedes, admin_g) también
--  la puede anular con el turno cerrado. Además de anularla y devolver el stock,
--  anular_factura_caja() corrige los cierres ya guardados que la contaban:
--    · Todos los cierres cerrados de ese día y sede que se cerraron después de
--      la factura (el "facturado" de cada cierre es el acumulado del día).
--    · En cada uno: facturado (métodos, total, minita, desglose), total de
--      ventas, tarjeta, SINPE, minita y la diferencia, con la misma fórmula del
--      cuadre de caja.html. El efectivo contado no se toca: es lo que se contó.
--    · Si la factura tenía SINPE y el cierre final de ese día ya se hizo, el
--      saldo SINPE vigente de la sede sube por ese monto y queda una aclaración
--      tipo 'factura' en sinpe_aclaraciones (como cuando se anula una factura
--      duplicada después del cierre).
--    · Cada cierre guarda la anulación en facturado.anuladas_post para que se
--      vea en el historial.
--  Coordinadores siguen pudiendo anular solo con el turno abierto.
-- ══════════════════════════════════════════════════════════════════════════

-- Monto de una factura en un método (pago dividido o un solo método)
create or replace function _fx_monto_metodo(f facturas_caja, m text)
returns numeric language sql immutable as $$
  select case when jsonb_typeof(f.pagos) = 'array' and jsonb_array_length(f.pagos) > 0
              then coalesce((select sum(coalesce((p ->> 'monto')::numeric, 0)) from jsonb_array_elements(f.pagos) p
                              where p ->> 'metodo' = m), 0)
              when f.metodo = m then coalesce(f.total, 0) else 0 end;
$$;

-- Saca una factura anulada de los cierres ya cerrados que la contaban
create or replace function _ajustar_cierres_anulacion(p_factura uuid, p_email text, p_motivo text)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_f    facturas_caja%rowtype;
  v_c    cierres_caja%rowtype;
  v_ef   numeric; v_tj numeric; v_sp numeric; v_t numeric; v_prod numeric; v_ev numeric;
  v_fx   jsonb;
  v_des  jsonb;
  v_it   jsonb;
  v_k    text;
  v_dif  numeric;
  v_n    int := 0;
  v_final_ok boolean := false;
  v_s    cierres_caja%rowtype;
  v_antes numeric;
  v_nota text;
  v_info jsonb;
begin
  select * into v_f from facturas_caja where id = p_factura;
  if not found then return 0; end if;
  v_t  := round(coalesce(v_f.total, 0));
  v_ef := round(_fx_monto_metodo(v_f, 'efectivo'));
  v_tj := round(_fx_monto_metodo(v_f, 'tarjeta'));
  v_sp := round(_fx_monto_metodo(v_f, 'sinpe'));
  v_ev := case when v_f.tipo = 'evento' then v_t else 0 end;
  v_prod := v_t - v_ev;
  v_info := jsonb_build_object('numero', v_f.numero, 'total', v_t, 'efectivo', v_ef, 'tarjeta', v_tj, 'sinpe', v_sp,
                               'motivo', p_motivo, 'por', p_email, 'at', now());

  for v_c in select * from cierres_caja
              where sede = v_f.sede and fecha = v_f.fecha and estado in ('parcial', 'final')
                and facturado is not null and hora_cierre >= v_f.created_at
              order by turno_num for update loop
    v_fx := v_c.facturado;
    -- Desglose de la minita: se rebaja el producto (la clave es el nombre normalizado; se busca por "base")
    v_des := coalesce(v_fx -> 'desglose', '{}'::jsonb);
    if v_f.tipo is distinct from 'evento' then
      for v_it in select * from jsonb_array_elements(coalesce(v_f.items, '[]'::jsonb)) loop
        v_k := null;
        select k into v_k from jsonb_each(v_des) e(k, v)
         where lower(btrim(v ->> 'base')) = lower(btrim(v_it ->> 'producto')) limit 1;
        if v_k is not null then
          v_des := jsonb_set(v_des, array[v_k], (v_des -> v_k) || jsonb_build_object(
                     'qty',   greatest(0, coalesce((v_des -> v_k ->> 'qty')::numeric, 0) - coalesce((v_it ->> 'cantidad')::numeric, 0)),
                     'total', greatest(0, coalesce((v_des -> v_k ->> 'total')::numeric, 0) - round(coalesce((v_it ->> 'total')::numeric, 0)))));
          if coalesce((v_des -> v_k ->> 'qty')::numeric, 0) <= 0 then v_des := v_des - v_k; end if;
        end if;
      end loop;
    end if;
    v_fx := v_fx || jsonb_build_object(
      'efectivo',  coalesce((v_fx ->> 'efectivo')::numeric, 0) - v_ef,
      'tarjeta',   coalesce((v_fx ->> 'tarjeta')::numeric, 0) - v_tj,
      'sinpe',     coalesce((v_fx ->> 'sinpe')::numeric, 0) - v_sp,
      'total',     coalesce((v_fx ->> 'total')::numeric, 0) - v_t,
      'productos', coalesce((v_fx ->> 'productos')::numeric, (v_fx ->> 'total')::numeric, 0) - v_prod,
      'eventos',   coalesce((v_fx ->> 'eventos')::numeric, 0) - v_ev,
      'n',         greatest(0, coalesce((v_fx ->> 'n')::int, 0) - 1),
      'desglose',  v_des,
      'anuladas_post', coalesce(v_fx -> 'anuladas_post', '[]'::jsonb) || jsonb_build_array(v_info));

    -- Cuadre (caja.html → cuadre()): diferencia = ventas − (efectivo + tarjeta + SINPE + transf + sobre + gastos − ingresos − fondo).
    -- Baja la venta; bajan tarjeta y SINPE; el sobre ya sacado ("ya", solo cierre final) baja con la minita.
    v_dif := round(coalesce(v_c.diferencia, 0)) - v_t + v_tj + v_sp
             + case when v_c.estado = 'final' and v_c.sobre_modo = 'ya' then v_prod else 0 end;

    update cierres_caja set
      facturado      = v_fx,
      total_ventas   = coalesce(total_ventas, 0) - v_t,
      total_tarjeta  = case when total_tarjeta is null then null else total_tarjeta - v_tj end,
      total_sinpe    = case when total_sinpe   is null then null else total_sinpe   - v_sp end,
      minita         = greatest(0, coalesce(minita, 0) - v_prod),
      otros_vendidos = greatest(0, coalesce(otros_vendidos, 0) - v_prod),
      diferencia     = v_dif,
      estado_dif     = case when v_dif = 0 then 'OK' when v_dif > 0 then 'Faltante' else 'Sobrante' end,
      sinpe_reporte  = case when v_c.estado = 'final' and v_sp > 0 and sinpe_reporte is not null
                            then sinpe_reporte || jsonb_build_object('facturado', coalesce((sinpe_reporte ->> 'facturado')::numeric, 0) - v_sp)
                            else sinpe_reporte end
    where id = v_c.id;
    v_n := v_n + 1;
    if v_c.estado = 'final' and v_c.sinpe_reporte is not null then v_final_ok := true; end if;
  end loop;

  -- SINPE ya conciliado en el cierre final: el saldo vigente de la sede sube por lo que se dejó de facturar
  if v_sp > 0 and v_final_ok then
    select * into v_s from cierres_caja
     where sede = v_f.sede and sinpe_pendiente is not null
     order by fecha desc, created_at desc limit 1 for update;
    if found then
      v_antes := round(v_s.sinpe_pendiente);
      v_nota := 'Factura #' || v_f.numero || ' de caja del ' || to_char(v_f.fecha, 'DD/MM/YYYY') || ' (SINPE ₡' || v_sp
                || ') anulada después del cierre: ' || coalesce(p_motivo, '');
      insert into sinpe_aclaraciones (sede, cierre_id, cierre_fecha, tipo, pendiente_antes, monto, pendiente_despues,
                                      nota, referencias, hecho_por, dias_marcados)
      values (v_f.sede, v_s.id, v_s.fecha, 'factura', v_antes, v_sp, v_antes + v_sp, left(v_nota, 1000),
              jsonb_build_array(jsonb_build_object('factura', '#' || v_f.numero, 'fecha', v_f.fecha, 'monto', v_sp,
                                                   'referencia', v_f.referencia)),
              p_email, true);
      update cierres_caja
         set sinpe_pendiente = v_antes + v_sp,
             sinpe_reporte = jsonb_set(coalesce(sinpe_reporte, '{}'::jsonb)
               || jsonb_build_object('aclaraciones', coalesce(sinpe_reporte -> 'aclaraciones', '[]'::jsonb)
                    || jsonb_build_array(jsonb_build_object('tipo', 'factura', 'antes', v_antes, 'monto', v_sp,
                         'despues', v_antes + v_sp, 'nota', left(v_nota, 1000), 'por', p_email, 'at', now(), 'refs', 1))),
               '{pendAfter}', to_jsonb(v_antes + v_sp))
       where id = v_s.id;
    end if;
  end if;
  return v_n;
end;
$$;
revoke all on function _ajustar_cierres_anulacion(uuid, text, text) from public;
revoke all on function _ajustar_cierres_anulacion(uuid, text, text) from authenticated;

create or replace function anular_factura_caja(p_factura uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_rol   text := public.mi_rol();
  v_email text := auth.jwt() ->> 'email';
  v_admin boolean := v_rol in ('admin','admin_sedes','admin_g');
  v_f     facturas_caja%rowtype;
  v_c     cierres_caja%rowtype;
  v_it    jsonb;
  v_inv   inventario%rowtype;
  v_qty   numeric;
  v_motivo text;
  v_cerrado boolean := false;
  v_ajustados int := 0;
begin
  select * into v_f from facturas_caja where id = p_factura for update;
  if not found then raise exception 'La factura no existe.'; end if;
  if v_f.estado = 'anulada' then raise exception 'La factura ya estaba anulada.'; end if;
  if nullif(btrim(coalesce(p_motivo, '')), '') is null then raise exception 'Indique el motivo de la anulación.'; end if;

  if not (v_admin or exists (
      select 1 from user_roles ur where ur.id = auth.uid() and ur.role = 'coordinador'
        and (ur.sede = v_f.sede or v_f.sede = any(ur.sedes_extra)))) then
    raise exception 'Solo un coordinador o un administrador puede anular facturas.' using errcode = '42501';
  end if;

  select * into v_c from cierres_caja where id = v_f.cierre_id for update;
  if not found or v_c.estado <> 'abierto' then
    if not v_admin then
      raise exception 'El turno de esta factura ya se cerró: solo Administración la puede anular.' using errcode = '42501';
    end if;
    v_cerrado := true;
  end if;

  v_motivo := 'venta: anulación de factura #' || v_f.numero || ' de caja';
  perform set_config('app.factura_caja', v_motivo, true);
  for v_it in select * from jsonb_array_elements(v_f.items) loop
    v_qty := (v_it ->> 'cantidad')::numeric;
    select * into v_inv from inventario where id = (v_it ->> 'inventario_id')::uuid for update;
    if not found then continue; end if;   -- producto borrado del inventario: no hay a dónde devolver
    if v_inv.desc_dia = (v_it ->> 'desc_dia')::date and coalesce(v_inv.desc_hoy, 0) >= v_qty then
      update inventario set cantidad = coalesce(cantidad, 0) + v_qty, desc_hoy = desc_hoy - v_qty, updated_at = now(),
             mov_motivo = v_motivo
       where id = v_inv.id;
    elsif v_admin then
      update inventario set cantidad = coalesce(cantidad, 0) + v_qty, updated_at = now(),
             mov_motivo = 'ajuste: anulación de factura #' || v_f.numero || ' de caja'
       where id = v_inv.id;
    else
      raise exception 'La venta de % es de otro día: la anulación la debe hacer un administrador.', v_inv.producto;
    end if;
  end loop;
  perform set_config('app.factura_caja', '', true);

  update facturas_caja
     set estado = 'anulada', motivo_anulacion = btrim(p_motivo), anulada_por = v_email, anulada_at = now()
   where id = p_factura;

  -- Turno cerrado: corregir los cierres guardados que contaban esta factura
  if v_cerrado then
    v_ajustados := _ajustar_cierres_anulacion(p_factura, v_email, btrim(p_motivo));
  end if;

  return jsonb_build_object('id', v_f.id, 'numero', v_f.numero, 'turno_cerrado', v_cerrado, 'cierres_ajustados', v_ajustados);
end;
$$;
revoke all on function anular_factura_caja(uuid, text) from public;
grant execute on function anular_factura_caja(uuid, text) to authenticated;
