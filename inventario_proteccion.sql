-- ══════════════════════════════════════════════════════════════════════════
--  PROTECCIÓN DEL INVENTARIO
--  Correr UNA vez en el SQL editor de Supabase, DESPUÉS de seguridad_rls.sql
--  (usa la función mi_rol()). Se puede repetir sin problema.
--
--  Antes, recepción / admin_sucursal / coordinador podían poner cualquier
--  cantidad (o cambiar precio y nombre) mandando un cambio directo a la base,
--  por ejemplo desde las herramientas del navegador. Ahora, para esos roles:
--    · nombre, precio, mínimo, sede, moneda y activo: solo administradores.
--    · BAJAR cantidad: solo como venta del día, y la baja tiene que calzar con
--      las unidades vendidas registradas (cantidad + vendidas_hoy se mantiene).
--      El tipo "venta" del kardex lo decide la base, no la página.
--    · SUBIR cantidad: solo aceptando un envío pendiente de su sede, con la
--      función aceptar_envio(), que registra el envío y suma el stock en un
--      solo paso, con lo enviado según la base (no se puede inflar) y sin que
--      quien creó el envío lo acepte él mismo.
--    · Aplicar un arqueo (poner el stock igual al conteo): solo administradores.
--  Administradores (admin, admin_sedes, admin_g) y los procesos del servidor
--  no tienen restricción. Todo cambio sigue quedando en el kardex.
-- ══════════════════════════════════════════════════════════════════════════

-- Nombre de producto normalizado (igual que normP de caja.html: minúsculas,
-- sin tildes, espacios simples)
create or replace function norm_prod(t text)
returns text language sql immutable as $$
  select btrim(regexp_replace(lower(translate(coalesce(t,''),
    'ÁÀÄÂÉÈËÊÍÌÏÎÓÒÖÔÚÙÜÛÑáàäâéèëêíìïîóòöôúùüûñ',
    'AAAAEEEEIIIIOOOOUUUUNaaaaeeeeiiiioooouuuun')), '\s+', ' ', 'g'))
$$;

-- ── Regla sobre cada cambio de inventario ───────────────────────────────────
create or replace function inventario_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_rol      text := public.mi_rol();
  v_hoy      date := (now() at time zone 'America/Costa_Rica')::date;
  v_envio    text := coalesce(current_setting('app.envio_aceptado', true), '');
  v_delta    numeric;
  v_prior    numeric;
  v_vendidas numeric;
  v_libres   text[] := array['cantidad','desc_dia','desc_hoy','updated_at','mov_motivo'];
begin
  -- Administradores y procesos del servidor (sin usuario): sin restricción
  if auth.uid() is null or v_rol in ('admin','admin_sedes','admin_g') then
    return new;
  end if;

  -- 1) Fuera de la cantidad y el control de ventas, nada se puede cambiar
  if (to_jsonb(new) - v_libres) is distinct from (to_jsonb(old) - v_libres) then
    raise exception 'Solo un administrador puede cambiar el nombre, precio, mínimo o sede de un producto.'
      using errcode = '42501';
  end if;

  v_delta := coalesce(new.cantidad, 0) - coalesce(old.cantidad, 0);

  -- 2) Entrada por envío aceptado: la marca la pone aceptar_envio() en esta misma
  --    transacción; desde la página no se puede poner
  if v_envio <> '' then
    if v_delta < 0 or new.desc_dia is distinct from old.desc_dia or new.desc_hoy is distinct from old.desc_hoy then
      raise exception 'Un envío solo puede sumar stock.' using errcode = '42501';
    end if;
    return new;
  end if;

  -- 3) Cualquier otro cambio de cantidad tiene que ser venta del día:
  --    cantidad + unidades vendidas ese día se mantiene constante
  if v_delta <> 0 or new.desc_hoy is distinct from old.desc_hoy or new.desc_dia is distinct from old.desc_dia then
    if new.desc_dia is null or new.desc_dia < v_hoy - 3 or new.desc_dia > v_hoy + 1 then
      raise exception 'Fecha de ventas fuera de rango para descontar inventario.' using errcode = '42501';
    end if;
    if coalesce(new.desc_hoy, 0) < 0 then
      raise exception 'Unidades vendidas inválidas.' using errcode = '42501';
    end if;
    v_prior    := case when old.desc_dia = new.desc_dia then coalesce(old.desc_hoy, 0) else 0 end;
    v_vendidas := coalesce(new.desc_hoy, 0) - v_prior;
    if v_vendidas <> -v_delta then
      raise exception 'El inventario solo baja por ventas del día y solo sube aceptando un envío. Para cualquier ajuste, pídalo a un administrador.'
        using errcode = '42501';
    end if;
    if v_delta <> 0 then
      -- El tipo lo decide la base. facturar_caja()/anular_factura_caja() ponen la marca en su
      -- transacción (ver facturacion.sql); desde la página no se puede poner.
      new.mov_motivo := coalesce(nullif(current_setting('app.factura_caja', true), ''),
                                 'venta: informe de ventas del ' || to_char(new.desc_dia, 'YYYY-MM-DD'));
    else
      new.mov_motivo := null;
    end if;
  end if;
  return new;
end;
$$;

-- Debe correr ANTES que el trigger del kardex (inventario_mov_log_trg): los
-- triggers del mismo momento se ejecutan en orden alfabético de nombre
drop trigger if exists inventario_a_guard_trg on inventario;
create trigger inventario_a_guard_trg
  before update on inventario
  for each row execute function inventario_guard();

-- ── Aceptar un envío: registra y suma en un solo paso ───────────────────────
-- p_recibidos: arreglo con lo recibido de cada ítem, en el mismo orden que
-- envios_mercaderia.items. Lo recibido se limita a lo ENVIADO según la base.
create or replace function aceptar_envio(p_envio uuid, p_recibidos jsonb, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_rol     text := public.mi_rol();
  v_email   text := auth.jwt() ->> 'email';
  v_env     envios_mercaderia%rowtype;
  v_items   jsonb := '[]'::jsonb;
  v_it      jsonb;
  v_i       int := 0;
  v_env_q   numeric;
  v_rec     numeric;
  v_inv     uuid;
  v_sumados int := 0;
  v_faltan  text[] := '{}';
begin
  select * into v_env from envios_mercaderia where id = p_envio for update;
  if not found then raise exception 'El envío no existe.'; end if;
  if coalesce(v_env.estado, 'pendiente') <> 'pendiente' then raise exception 'Este envío ya fue aceptado.'; end if;

  -- Permiso: administradores, o personal de esa sede (principal o extra)
  if not (v_rol in ('admin','admin_sedes','admin_g') or exists (
      select 1 from user_roles ur where ur.id = auth.uid()
        and ur.role in ('recepcion','admin_sucursal','coordinador')
        and (ur.sede = v_env.sede or v_env.sede = any(ur.sedes_extra)))) then
    raise exception 'No puede aceptar envíos de esta sede.' using errcode = '42501';
  end if;
  -- Quien creó el envío no puede aceptarlo (salvo administradores)
  if v_rol not in ('admin','admin_sedes','admin_g') and v_env.created_by is not null
     and lower(v_env.created_by) = lower(coalesce(v_email, '')) then
    raise exception 'Quien creó el envío no puede aceptarlo: debe hacerlo otra persona de la sede.' using errcode = '42501';
  end if;

  perform set_config('app.envio_aceptado', p_envio::text, true);   -- habilita la suma en inventario_guard

  for v_it in select * from jsonb_array_elements(v_env.items) loop
    v_env_q := greatest(coalesce((v_it ->> 'enviado')::numeric, 0), 0);
    v_rec   := least(greatest(coalesce((p_recibidos ->> v_i)::numeric, 0), 0), v_env_q);
    v_items := v_items || jsonb_set(v_it, '{recibido}', to_jsonb(v_rec));
    if v_rec > 0 then
      select id into v_inv from inventario
       where sede = v_env.sede and norm_prod(producto) = norm_prod(v_it ->> 'producto') limit 1;
      if v_inv is not null then
        update inventario
           set cantidad = coalesce(cantidad, 0) + v_rec, updated_at = now(),
               mov_motivo = 'entrada: envío aceptado (enviado por ' || coalesce(v_env.created_by, '—') || ')'
         where id = v_inv;
        v_sumados := v_sumados + 1;
      else
        v_faltan := v_faltan || (v_it ->> 'producto');
      end if;
    end if;
    v_i := v_i + 1;
  end loop;

  perform set_config('app.envio_aceptado', '', true);

  update envios_mercaderia
     set estado = 'aceptado', items = v_items, nota = p_nota,
         aceptado_por = v_email, aceptado_at = now()
   where id = p_envio;

  return jsonb_build_object('sumados', v_sumados, 'no_existen', to_jsonb(v_faltan));
end;
$$;

revoke all on function aceptar_envio(uuid, jsonb, text) from public;
grant execute on function aceptar_envio(uuid, jsonb, text) to authenticated;

-- Recepción ya no modifica envíos directamente (se podían inflar las cantidades
-- antes de aceptar): lo hace solo a través de aceptar_envio(). Sigue pudiendo verlos.
drop policy if exists envios_recep_update on envios_mercaderia;

-- ── Comprobación ────────────────────────────────────────────────────────────
select tgname as trigger, tgenabled from pg_trigger
where tgrelid = 'inventario'::regclass and not tgisinternal order by tgname;
