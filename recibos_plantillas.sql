-- ══════════════════════════════════════════════════════════════════════════
--  RECIBOS (pagos sin factura por clase) y PLANTILLAS semanales
--  Correr en Supabase → SQL Editor, DESPUÉS de pagos_instructores.sql y
--  horas_instructores.sql. Se puede repetir sin problema.
--
--  · Recibo: instructores que cobran por clase (p. ej. CrossFit) pero no dan
--    factura. Recepción registra las clases en Gastos → «🧾 Recibos» y se
--    guardan como gasto de Clases grupales con origen 'recibo'. El día de pago
--    sale igual que las facturas: por la HORA EN QUE SE REGISTRA (corte
--    miércoles y viernes 10:00 a. m.); fines de semana, caja.
--  · Plantillas: las clases (recibos) o las horas (planilla por horas) fijas
--    de cada persona por día de la semana, para no volver a anotarlas.
-- ══════════════════════════════════════════════════════════════════════════

-- 1) El día de pago de los recibos lo pone la base, igual que el de las facturas
create or replace function gastos_xml_dia_pago()
returns trigger language plpgsql as $$
declare
  recibida timestamptz;
begin
  if new.origen is null or new.origen not in ('xml', 'recibo') then return new; end if;
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

-- 2) Marcar pagado también los recibos
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
     and g.origen in ('xml', 'horas', 'recibo')
     and (r.role in ('admin','admin_sedes','admin_g')
          or g.sede = r.sede or g.sede = any(coalesce(r.sedes_extra, '{}')));
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function marcar_pago_instructor(uuid[], boolean) from anon;

-- 3) Plantillas semanales -----------------------------------------------------
create table if not exists plantillas_pago (
  id            uuid primary key default gen_random_uuid(),
  sede          text not null,
  tipo          text not null check (tipo in ('horas', 'recibo')),
  instructor_id uuid not null references instructores(id) on delete cascade,
  tarifa_id     uuid not null,      -- hora_tarifas.id (horas) o clase_tarifas.id (recibo)
  dias          jsonb not null default '[0,0,0,0,0,0,0]',   -- lunes … domingo: horas, o cantidad de clases
  updated_by    text,
  updated_at    timestamptz default now(),
  unique (sede, tipo, instructor_id, tarifa_id)
);

create or replace function plantillas_pago_guard()
returns trigger language plpgsql as $$
begin
  if jsonb_typeof(new.dias) <> 'array' or jsonb_array_length(new.dias) <> 7
     or exists (select 1 from jsonb_array_elements(new.dias) v
                where jsonb_typeof(v) <> 'number' or v::text::numeric < 0 or v::text::numeric > 24) then
    raise exception 'La plantilla debe tener 7 días con valores entre 0 y 24.';
  end if;
  if new.tipo = 'horas' and not exists (select 1 from hora_tarifas t where t.id = new.tarifa_id) then
    raise exception 'Tarifa por hora no encontrada.';
  end if;
  if new.tipo = 'recibo' and not exists (select 1 from clase_tarifas t where t.id = new.tarifa_id) then
    raise exception 'Tipo de clase no encontrado.';
  end if;
  new.updated_at := now();
  new.updated_by := coalesce(auth.jwt() ->> 'email', new.updated_by);
  return new;
end $$;
drop trigger if exists plantillas_pago_guard_trg on plantillas_pago;
create trigger plantillas_pago_guard_trg before insert or update on plantillas_pago
  for each row execute function plantillas_pago_guard();

-- RLS: coordinador, recepción y admin de sucursal en su sede (o sedes extra); admins en todas
alter table plantillas_pago enable row level security;
drop policy if exists plantillas_pago_todo on plantillas_pago;
create policy plantillas_pago_todo on plantillas_pago for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
         and (ur.role in ('admin','admin_sedes','admin_g')
              or (ur.role in ('recepcion','coordinador','admin_sucursal') and (ur.sede = plantillas_pago.sede or plantillas_pago.sede = any(ur.sedes_extra))))))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
         and (ur.role in ('admin','admin_sedes','admin_g')
              or (ur.role in ('recepcion','coordinador','admin_sucursal') and (ur.sede = plantillas_pago.sede or plantillas_pago.sede = any(ur.sedes_extra))))));

-- Comprobación
select count(*) as plantillas from plantillas_pago;
