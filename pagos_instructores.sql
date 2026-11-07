-- ══════════════════════════════════════════════════════════════════════════
--  PAGOS A INSTRUCTORES — facturas electrónicas (XML) de clases grupales
--  Correr en Supabase → SQL Editor, después de gastos.sql. Se puede repetir.
--
--  Flujo:
--    · Recepción / coordinador / admin sube el XML de la factura en Gastos →
--      «Cargar factura XML». Se valida y se guarda como un gasto más
--      (categoría clases_grupales), así el resumen mensual no cambia.
--    · El DÍA DE PAGO lo pone la base con la hora del servidor (Costa Rica):
--        cargada antes del miércoles 10:00 a. m.            → miércoles
--        del miércoles 10:00 a. m. al viernes 10:00 a. m.   → viernes
--        después del viernes 10:00 a. m.                    → miércoles siguiente
--      Las clases de fin de semana se marcan «caja»: no tienen día de pago.
--    · Una factura no se puede cargar dos veces (clave de Hacienda única).
--    · El instructor también puede enviarla él mismo desde la página pública
--      /factura (sin usuario). Queda «pendiente» hasta que administración la
--      aprueba en Gastos → «Por aprobar»; para el corte cuenta la hora en
--      que el instructor la ENVIÓ, no la hora de la aprobación.
-- ══════════════════════════════════════════════════════════════════════════

-- 1) Cédula del instructor: así se le reconoce en el XML ---------------------
alter table instructores add column if not exists cedula text;   -- solo dígitos
create unique index if not exists instructores_cedula_uidx on instructores (cedula) where cedula is not null;

-- 2) Razón social de cada sede: la factura debe venir a su nombre ------------
create table if not exists sedes_fiscal (
  sede            text primary key,          -- '3 Ríos' | 'Natación' | 'Pinares' | 'Sabanilla'
  razon_social    text,
  cedula_juridica text,                      -- solo dígitos
  updated_at      timestamptz default now(),
  updated_by      text
);

-- 3) Tarifa por tipo de clase -------------------------------------------------
create table if not exists clase_tarifas (
  id         uuid primary key default gen_random_uuid(),
  tipo       text not null,                  -- 'Baile', 'CrossFit', …
  monto      numeric not null check (monto > 0),
  activo     boolean not null default true,
  created_at timestamptz default now()
);
create unique index if not exists clase_tarifas_tipo_uidx on clase_tarifas (lower(tipo));
insert into clase_tarifas (tipo, monto) values ('Baile', 13000), ('CrossFit', 12000)
  on conflict do nothing;

-- 4) Columnas nuevas en gastos ----------------------------------------------
alter table gastos add column if not exists origen          text default 'manual';  -- 'manual' | 'xml'
alter table gastos add column if not exists clave_hacienda  text;     -- clave de 50 dígitos de la factura
alter table gastos add column if not exists emisor_cedula   text;
alter table gastos add column if not exists detalle_clases  jsonb;    -- [{fecha, tipo, cantidad, tarifa, subtotal}]
alter table gastos add column if not exists monto_esperado  numeric;  -- clases × tarifa
alter table gastos add column if not exists nota_diferencia text;     -- obligatoria si el monto no calza
alter table gastos add column if not exists pago_tipo       text;     -- 'transferencia' | 'caja'
alter table gastos add column if not exists dia_pago        date;     -- miércoles o viernes (lo pone la base)
alter table gastos add column if not exists cargado_at      timestamptz;
alter table gastos add column if not exists pagado_at       timestamptz;
alter table gastos add column if not exists pagado_por      text;
create unique index if not exists gastos_clave_hacienda_uidx on gastos (clave_hacienda) where clave_hacienda is not null;
create index if not exists gastos_dia_pago_idx on gastos (sede, dia_pago) where dia_pago is not null;
alter table gastos add column if not exists factura_pendiente_id uuid;   -- si vino del portal del instructor

-- Facturas que envía el instructor desde /factura, esperando aprobación ------
create table if not exists facturas_pendientes (
  id              uuid primary key default gen_random_uuid(),
  sede            text not null,             -- según la cédula jurídica del receptor
  clave_hacienda  text not null,
  numero_factura  text,
  emisor_nombre   text,
  emisor_cedula   text,
  monto           numeric,
  fecha_emision   text,
  xml             text not null,
  nombre_archivo  text,
  clases          jsonb,                     -- [{fecha, tipo, cantidad}] según el instructor
  pago_forma      text,                      -- 'sinpe' | 'bac' | 'otro_banco' (opcional)
  pago_banco      text,
  pago_numero     text,
  telefono        text,
  nota            text,
  estado          text not null default 'pendiente' check (estado in ('pendiente','aprobada','rechazada')),
  motivo_rechazo  text,
  revisado_por    text,
  revisado_at     timestamptz,
  gasto_id        uuid references gastos(id) on delete set null,
  created_at      timestamptz not null default now()
);
-- Una factura rechazada se puede volver a enviar; una pendiente o aprobada no
create unique index if not exists facturas_pend_clave_uidx on facturas_pendientes (clave_hacienda) where estado <> 'rechazada';
create index if not exists facturas_pend_estado_idx on facturas_pendientes (estado, created_at);

-- El XML tal como se subió, aparte para que la lista de gastos no lo descargue
create table if not exists gastos_xml (
  gasto_id       uuid primary key references gastos(id) on delete cascade,
  xml            text not null,
  nombre_archivo text,
  created_at     timestamptz default now()
);
alter table gastos_xml enable row level security;
-- Quien puede ver el gasto (según las políticas de gastos) puede ver y subir su XML
drop policy if exists gastos_xml_select on gastos_xml;
create policy gastos_xml_select on gastos_xml for select to authenticated
  using (exists (select 1 from gastos g where g.id = gasto_id));
drop policy if exists gastos_xml_insert on gastos_xml;
create policy gastos_xml_insert on gastos_xml for insert to authenticated
  with check (exists (select 1 from gastos g where g.id = gasto_id));

-- 5) Día de pago según la hora de carga --------------------------------------
create or replace function dia_pago_instructor(p_ts timestamptz)
returns date language plpgsql stable as $$
declare
  l timestamp := p_ts at time zone 'America/Costa_Rica';
  d date := l::date;
  i int;
begin
  for i in 0..7 loop
    -- isodow: 3 = miércoles, 5 = viernes; corte a las 10:00 a. m. de ese día
    if extract(isodow from d + i) in (3, 5) and l < (d + i) + time '10:00' then
      return d + i;
    end if;
  end loop;
  return null;
end $$;

-- El navegador no decide la hora ni el día de pago: los fija este trigger.
create or replace function gastos_xml_dia_pago()
returns trigger language plpgsql as $$
declare
  recibida timestamptz;
begin
  if new.origen is distinct from 'xml' then return new; end if;
  if tg_op = 'INSERT' then
    -- Enviada por el instructor: el corte se mide con la hora en que la envió
    if new.factura_pendiente_id is not null then
      select p.created_at into recibida from facturas_pendientes p
       where p.id = new.factura_pendiente_id and p.estado = 'pendiente';
    end if;
    new.cargado_at := coalesce(recibida, now());
    new.pagado_at  := null;
    new.pagado_por := null;
  else
    new.cargado_at := old.cargado_at;
  end if;
  if new.pago_tipo = 'caja' then
    new.dia_pago := null;
  else
    new.pago_tipo := 'transferencia';
    new.dia_pago  := dia_pago_instructor(coalesce(new.cargado_at, now()));
  end if;
  return new;
end $$;

drop trigger if exists gastos_xml_dia_pago_trg on gastos;
create trigger gastos_xml_dia_pago_trg
  before insert or update on gastos
  for each row execute function gastos_xml_dia_pago();

-- Al aprobar una factura del portal, queda marcada como aprobada en el mismo paso
create or replace function gastos_marca_pendiente()
returns trigger language plpgsql as $$
begin
  update facturas_pendientes
     set estado = 'aprobada', gasto_id = new.id, revisado_at = now(),
         revisado_por = coalesce(auth.jwt() ->> 'email', new.created_by)
   where id = new.factura_pendiente_id and estado = 'pendiente';
  return new;
end $$;

drop trigger if exists gastos_marca_pendiente_trg on gastos;
create trigger gastos_marca_pendiente_trg
  after insert on gastos
  for each row when (new.factura_pendiente_id is not null)
  execute function gastos_marca_pendiente();

-- 6) ¿Ya se cargó esta factura? (en cualquier sede, o enviada por el instructor)
--    Recepción solo ve los gastos de su sede; esto le dice dónde está la otra.
drop function if exists factura_ya_cargada(text);
create or replace function factura_ya_cargada(p_clave text, p_excluir uuid default null)
returns table (sede text, created_by text, cargado_at timestamptz, numero_factura text)
language sql stable security definer set search_path = public as $$
  select * from (
    select g.sede, g.created_by, coalesce(g.cargado_at, g.created_at), g.numero_factura
      from gastos g where g.clave_hacienda = p_clave
    union all
    select p.sede, 'el instructor (pendiente de aprobación)', p.created_at, p.numero_factura
      from facturas_pendientes p
     where p.clave_hacienda = p_clave and p.estado = 'pendiente'
       and p.id is distinct from p_excluir
  ) t
  where exists (select 1 from user_roles ur where ur.id = auth.uid())
  limit 1;
$$;

-- 7) Marcar pagado / pendiente ------------------------------------------------
--    Admins en cualquier sede; coordinador y admin de sucursal en las suyas.
create or replace function marcar_pago_instructor(p_ids uuid[], p_pagado boolean)
returns integer language plpgsql security definer set search_path = public as $$
declare
  r record;
  n integer;
  quien text := coalesce(auth.jwt() ->> 'email', auth.uid()::text);
begin
  select role, sede, sedes_extra into r from user_roles where id = auth.uid();
  if r.role is null or r.role not in ('admin','admin_sedes','admin_g','coordinador','admin_sucursal') then
    raise exception 'Su cuenta no puede marcar pagos.';
  end if;
  update gastos g
     set pagado_at  = case when p_pagado then now() end,
         pagado_por = case when p_pagado then quien end
   where g.id = any(p_ids)
     and g.origen in ('xml', 'horas')
     and (r.role in ('admin','admin_sedes','admin_g')
          or g.sede = r.sede or g.sede = any(coalesce(r.sedes_extra, '{}')));
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function factura_ya_cargada(text, uuid) from anon;
revoke execute on function marcar_pago_instructor(uuid[], boolean) from anon;

-- ══════════════════════════════════════════════════════════════════════════
--  Row Level Security: todos los usuarios con sesión leen; solo admins editan.
-- ══════════════════════════════════════════════════════════════════════════
alter table sedes_fiscal enable row level security;
drop policy if exists sedes_fiscal_select on sedes_fiscal;
create policy sedes_fiscal_select on sedes_fiscal for select to authenticated using (true);
drop policy if exists sedes_fiscal_admin on sedes_fiscal;
create policy sedes_fiscal_admin on sedes_fiscal for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes','admin_g')))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes','admin_g')));

alter table clase_tarifas enable row level security;
drop policy if exists clase_tarifas_select on clase_tarifas;
create policy clase_tarifas_select on clase_tarifas for select to authenticated using (true);
drop policy if exists clase_tarifas_admin on clase_tarifas;
create policy clase_tarifas_admin on clase_tarifas for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes','admin_g')))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes','admin_g')));

-- ══════════════════════════════════════════════════════════════════════════
--  8) Portal público del instructor (/factura, sin usuario)
--     El navegador no puede leer ni escribir tablas: solo estas funciones,
--     que vuelven a leer y validar el XML aquí, en el servidor.
-- ══════════════════════════════════════════════════════════════════════════
alter table facturas_pendientes enable row level security;
drop policy if exists facturas_pend_admin on facturas_pendientes;
create policy facturas_pend_admin on facturas_pendientes for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes','admin_g')))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes','admin_g')));

-- Tipos de clase (solo nombres: las tarifas no se muestran al público)
create or replace function tipos_clase_publicos()
returns setof text language sql stable security definer set search_path = public as $$
  select tipo from clase_tarifas where activo order by tipo;
$$;

-- Sede según la cédula jurídica a la que viene la factura (dato público de la empresa)
create or replace function sede_por_receptor(p_cedula text)
returns text language sql stable security definer set search_path = public as $$
  select sede from sedes_fiscal
   where regexp_replace(coalesce(cedula_juridica,''), '\D', '', 'g') = regexp_replace(coalesce(p_cedula,''), '\D', '', 'g')
     and coalesce(cedula_juridica,'') <> ''
   limit 1;
$$;

-- Texto de un nodo del XML (ignora los espacios de nombres de Hacienda)
create or replace function _fe_texto(x xml, ruta text)
returns text language sql immutable as $$
  select nullif(trim(replace(replace(replace(replace((xpath(ruta, x))[1]::text,
         '&lt;','<'),'&gt;','>'),'&quot;','"'),'&amp;','&')), '');
$$;

create or replace function enviar_factura_instructor(
  p_xml text, p_nombre_archivo text, p_clases jsonb,
  p_pago_forma text default null, p_pago_banco text default null, p_pago_numero text default null,
  p_telefono text default null, p_nota text default null)
returns table (id uuid, sede text, monto numeric, recibida timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  x xml; raiz text; clave text; consecutivo text; emisor_ced text; receptor_ced text;
  v_sede text; v_total numeric; v_moneda text; clases_ok jsonb := '[]'::jsonb; c jsonb;
  v_tipo text; v_cant int; v_fecha date; nuevo facturas_pendientes;
begin
  if p_xml is null or length(p_xml) > 300000 then raise exception 'El archivo no parece el XML de una factura.'; end if;
  -- Freno contra envíos masivos
  if (select count(*) from facturas_pendientes where created_at > now() - interval '10 minutes') >= 40 then
    raise exception 'Hay demasiados envíos en este momento. Intente de nuevo en unos minutos.';
  end if;
  begin
    x := xmlparse(document regexp_replace(p_xml, '^\s*\uFEFF?\s*<\?xml[^>]*\?>', ''));
  exception when others then
    raise exception 'El archivo no es un XML válido.';
  end;
  raiz := (xpath('local-name(/*)', x))[1]::text;
  if raiz is distinct from 'FacturaElectronica' then
    raise exception 'El archivo no es una factura electrónica (es %). Suba el XML de la factura, no la respuesta de Hacienda.', coalesce(raiz, 'otro documento');
  end if;
  clave        := regexp_replace(coalesce(_fe_texto(x, '/*/*[local-name()="Clave"]/text()'),''), '\D', '', 'g');
  consecutivo  := regexp_replace(coalesce(_fe_texto(x, '/*/*[local-name()="NumeroConsecutivo"]/text()'),''), '\D', '', 'g');
  emisor_ced   := regexp_replace(coalesce(_fe_texto(x, '/*/*[local-name()="Emisor"]/*[local-name()="Identificacion"]/*[local-name()="Numero"]/text()'),''), '\D', '', 'g');
  receptor_ced := regexp_replace(coalesce(_fe_texto(x, '/*/*[local-name()="Receptor"]/*[local-name()="Identificacion"]/*[local-name()="Numero"]/text()'),''), '\D', '', 'g');
  v_moneda     := coalesce(_fe_texto(x, '/*/*[local-name()="ResumenFactura"]//*[local-name()="CodigoMoneda"]/text()'), 'CRC');
  begin
    v_total := _fe_texto(x, '/*/*[local-name()="ResumenFactura"]/*[local-name()="TotalComprobante"]/text()')::numeric;
  exception when others then v_total := null; end;

  if clave !~ '^\d{50}$' or substr(clave, 10, 12) <> lpad(emisor_ced, 12, '0') or substr(clave, 22, 20) <> consecutivo then
    raise exception 'La clave de la factura no coincide con el emisor o el número: revise que sea el XML correcto.';
  end if;
  if v_total is null or v_total <= 0 then raise exception 'No se encontró el total de la factura.'; end if;
  if v_moneda <> 'CRC' then raise exception 'La factura está en %. Debe ser en colones.', v_moneda; end if;
  v_sede := sede_por_receptor(receptor_ced);
  if v_sede is null then
    raise exception 'La factura no está a nombre de ninguna de nuestras sedes (receptor %). Emítala a nombre de la razón social de la sede donde dio la clase.', coalesce(nullif(receptor_ced,''), 'vacío');
  end if;
  if exists (select 1 from gastos g where g.clave_hacienda = clave)
     or exists (select 1 from facturas_pendientes p where p.clave_hacienda = clave and p.estado <> 'rechazada') then
    raise exception 'Esta factura ya fue enviada.';
  end if;

  -- Clases que indica el instructor
  if jsonb_typeof(p_clases) <> 'array' or jsonb_array_length(p_clases) not between 1 and 20 then
    raise exception 'Indique las clases que cubre la factura.';
  end if;
  for c in select * from jsonb_array_elements(p_clases) loop
    select t.tipo into v_tipo from clase_tarifas t where t.activo and lower(t.tipo) = lower(c ->> 'tipo');
    begin
      v_cant := (c ->> 'cantidad')::int;
      v_fecha := (c ->> 'fecha')::date;
    exception when others then v_cant := null; end;
    if v_tipo is null or v_cant is null or v_cant not between 1 and 30
       or v_fecha is null or v_fecha not between current_date - 120 and current_date + 1 then
      raise exception 'Revise las clases: fecha, tipo y cantidad.';
    end if;
    clases_ok := clases_ok || jsonb_build_object('fecha', v_fecha, 'tipo', v_tipo, 'cantidad', v_cant);
  end loop;
  if p_pago_forma is not null and p_pago_forma not in ('sinpe','bac','otro_banco') then p_pago_forma := null; end if;

  insert into facturas_pendientes (sede, clave_hacienda, numero_factura, emisor_nombre, emisor_cedula, monto,
         fecha_emision, xml, nombre_archivo, clases, pago_forma, pago_banco, pago_numero, telefono, nota)
  values (v_sede, clave, consecutivo,
          left(_fe_texto(x, '/*/*[local-name()="Emisor"]/*[local-name()="Nombre"]/text()'), 120), emisor_ced, v_total,
          left(_fe_texto(x, '/*/*[local-name()="FechaEmision"]/text()'), 40), p_xml, left(p_nombre_archivo, 120), clases_ok,
          p_pago_forma, left(nullif(trim(p_pago_banco),''), 60), left(nullif(trim(p_pago_numero),''), 60),
          left(nullif(trim(p_telefono),''), 30), left(nullif(trim(p_nota),''), 500))
  returning * into nuevo;
  return query select nuevo.id, nuevo.sede, nuevo.monto, nuevo.created_at;
exception when unique_violation then
  raise exception 'Esta factura ya fue enviada.';
end $$;

grant execute on function tipos_clase_publicos() to anon, authenticated;
grant execute on function sede_por_receptor(text) to anon, authenticated;
grant execute on function enviar_factura_instructor(text, text, jsonb, text, text, text, text, text) to anon, authenticated;

-- Comprobación
select dia_pago_instructor(now()) as proximo_dia_de_pago,
       (select count(*) from clase_tarifas) as tarifas;
