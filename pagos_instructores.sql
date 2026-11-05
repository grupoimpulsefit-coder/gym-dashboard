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
begin
  if new.origen is distinct from 'xml' then return new; end if;
  if tg_op = 'INSERT' then
    new.cargado_at := now();
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

-- 6) ¿Ya se cargó esta factura? (en cualquier sede) ---------------------------
--    Recepción solo ve los gastos de su sede; esto le dice dónde está la otra.
create or replace function factura_ya_cargada(p_clave text)
returns table (sede text, created_by text, cargado_at timestamptz, numero_factura text)
language sql stable security definer set search_path = public as $$
  select g.sede, g.created_by, coalesce(g.cargado_at, g.created_at), g.numero_factura
  from gastos g
  where g.clave_hacienda = p_clave
    and exists (select 1 from user_roles ur where ur.id = auth.uid())
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
     and g.origen = 'xml'
     and (r.role in ('admin','admin_sedes','admin_g')
          or g.sede = r.sede or g.sede = any(coalesce(r.sedes_extra, '{}')));
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function factura_ya_cargada(text) from anon;
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

-- Comprobación
select dia_pago_instructor(now()) as proximo_dia_de_pago,
       (select count(*) from clase_tarifas) as tarifas;
