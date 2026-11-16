-- ══════════════════════════════════════════════════════════════════════════
--  PLANILLA POR HORAS — instructores que no facturan y se les paga por hora
--  Correr en Supabase → SQL Editor, DESPUÉS de pagos_instructores.sql.
--  Se puede repetir sin problema.
--
--  Flujo (todo en Gastos → pestaña «🕐 Horas»):
--    · El coordinador o recepción anota las horas de cada persona por día
--      (semana de lunes a domingo) y la envía a aprobación. Un admin también
--      puede anotarlas, por una emergencia.
--    · Un admin la aprueba: cada persona queda como un gasto de
--      «Instructores de planta» y aparece en «Pago de la semana» el VIERNES
--      siguiente a la semana trabajada (lunes + 11 días).
--    · Tarifas fijas por hora (Configuración): Profesor de natación ₡3 500,
--      Instructor de planta ₡2 500. Sin deducciones por ahora; la columna
--      `deduccion` queda lista por si se necesitan (solo la edita un admin).
-- ══════════════════════════════════════════════════════════════════════════

-- 1) Tarifas por hora ---------------------------------------------------------
create table if not exists hora_tarifas (
  id         uuid primary key default gen_random_uuid(),
  tipo       text not null,                  -- 'Profesor de natación', 'Instructor de planta', …
  monto      numeric not null check (monto > 0),
  activo     boolean not null default true,
  created_at timestamptz default now()
);
create unique index if not exists hora_tarifas_tipo_uidx on hora_tarifas (lower(tipo));
insert into hora_tarifas (tipo, monto) values ('Profesor de natación', 3500), ('Instructor de planta', 2500)
  on conflict do nothing;

alter table hora_tarifas enable row level security;
drop policy if exists hora_tarifas_select on hora_tarifas;
create policy hora_tarifas_select on hora_tarifas for select to authenticated using (true);
drop policy if exists hora_tarifas_admin on hora_tarifas;
create policy hora_tarifas_admin on hora_tarifas for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes','admin_g')))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes','admin_g')));

-- 2) Quién cobra por horas (en el directorio de instructores) ----------------
--    Con esto aparecen solos en la semana de su sede; igual se puede agregar a
--    cualquier persona del directorio.
alter table instructores add column if not exists hora_tarifa_id uuid references hora_tarifas(id);
alter table instructores add column if not exists hora_sede      text;

-- 3) Horas de cada semana -----------------------------------------------------
create table if not exists horas_semana (
  id             uuid primary key default gen_random_uuid(),
  sede           text not null,
  semana         date not null,              -- lunes de la semana trabajada
  instructor_id  uuid not null references instructores(id),
  tarifa_id      uuid not null references hora_tarifas(id),
  tipo           text,                       -- copia de la tarifa al guardar
  tarifa         numeric,
  dias           jsonb not null default '[0,0,0,0,0,0,0]',   -- horas lunes … domingo
  horas          numeric not null default 0, -- la suma la calcula la base
  deduccion      numeric not null default 0, -- por ahora 0; solo admin
  nota           text,
  estado         text not null default 'borrador' check (estado in ('borrador','enviada','aprobada')),
  registrado_por text,
  updated_at     timestamptz default now(),
  enviado_at     timestamptz,
  aprobado_por   text,
  aprobado_at    timestamptz,
  gasto_id       uuid references gastos(id) on delete set null,
  unique (sede, semana, instructor_id, tarifa_id)
);
create index if not exists horas_semana_estado_idx on horas_semana (estado, sede, semana);

-- Validaciones, suma de horas y copia de la tarifa (no se confía en el navegador)
create or replace function horas_semana_guard()
returns trigger language plpgsql as $$
declare
  es_admin boolean := exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes','admin_g'));
  por_rpc  boolean := coalesce(current_setting('horas.rpc', true), '') = '1';
  t record;
begin
  if tg_op = 'UPDATE' and old.estado = 'aprobada' and not por_rpc then
    raise exception 'Esta semana ya fue aprobada. Un admin puede reabrirla.';
  end if;
  if new.estado = 'aprobada' and not por_rpc then
    raise exception 'La semana se aprueba con el botón «Aprobar».';
  end if;
  if por_rpc then return new; end if;
  if extract(isodow from new.semana) <> 1 then raise exception 'La semana debe empezar en lunes.'; end if;
  if jsonb_typeof(new.dias) <> 'array' or jsonb_array_length(new.dias) <> 7 then
    raise exception 'Horas por día inválidas.';
  end if;
  if exists (select 1 from jsonb_array_elements(new.dias) v
             where jsonb_typeof(v) <> 'number' or v::text::numeric < 0 or v::text::numeric > 24) then
    raise exception 'Cada día debe tener entre 0 y 24 horas.';
  end if;
  select coalesce(sum(v::text::numeric), 0) into new.horas from jsonb_array_elements(new.dias) v;
  select tipo, monto into t from hora_tarifas where id = new.tarifa_id;
  if t.tipo is null then raise exception 'Tarifa por hora no encontrada.'; end if;
  new.tipo := t.tipo; new.tarifa := t.monto;
  if not es_admin then new.deduccion := case when tg_op = 'UPDATE' then old.deduccion else 0 end; end if;
  if new.deduccion < 0 or new.deduccion > new.horas * new.tarifa then raise exception 'El rebajo no puede ser mayor que el pago.'; end if;
  if new.estado = 'enviada' and (tg_op = 'INSERT' or old.estado <> 'enviada') then new.enviado_at := now(); end if;
  new.updated_at := now();
  new.registrado_por := coalesce(auth.jwt() ->> 'email', new.registrado_por);
  return new;
end $$;

drop trigger if exists horas_semana_guard_trg on horas_semana;
create trigger horas_semana_guard_trg
  before insert or update on horas_semana
  for each row execute function horas_semana_guard();

-- RLS: coordinador, recepción y admin de sucursal en su sede (o sedes extra); admins en todas.
--      Nadie edita ni borra una semana aprobada (primero se reabre).
alter table horas_semana enable row level security;
drop policy if exists horas_semana_select on horas_semana;
create policy horas_semana_select on horas_semana for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
         and (ur.role in ('admin','admin_sedes','admin_g')
              or (ur.role in ('recepcion','coordinador','admin_sucursal') and (ur.sede = horas_semana.sede or horas_semana.sede = any(ur.sedes_extra))))));
drop policy if exists horas_semana_insert on horas_semana;
create policy horas_semana_insert on horas_semana for insert to authenticated
  with check (estado <> 'aprobada' and exists (select 1 from user_roles ur where ur.id = auth.uid()
         and (ur.role in ('admin','admin_sedes','admin_g')
              or (ur.role in ('recepcion','coordinador','admin_sucursal') and (ur.sede = horas_semana.sede or horas_semana.sede = any(ur.sedes_extra))))));
drop policy if exists horas_semana_update on horas_semana;
create policy horas_semana_update on horas_semana for update to authenticated
  using (estado <> 'aprobada' and exists (select 1 from user_roles ur where ur.id = auth.uid()
         and (ur.role in ('admin','admin_sedes','admin_g')
              or (ur.role in ('recepcion','coordinador','admin_sucursal') and (ur.sede = horas_semana.sede or horas_semana.sede = any(ur.sedes_extra))))))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
         and (ur.role in ('admin','admin_sedes','admin_g')
              or (ur.role in ('recepcion','coordinador','admin_sucursal') and (ur.sede = horas_semana.sede or horas_semana.sede = any(ur.sedes_extra))))));
drop policy if exists horas_semana_delete on horas_semana;
create policy horas_semana_delete on horas_semana for delete to authenticated
  using (estado <> 'aprobada' and exists (select 1 from user_roles ur where ur.id = auth.uid()
         and (ur.role in ('admin','admin_sedes','admin_g')
              or (ur.role in ('recepcion','coordinador','admin_sucursal') and (ur.sede = horas_semana.sede or horas_semana.sede = any(ur.sedes_extra))))));

-- 4) Aprobar una semana: un gasto por persona, para el viernes siguiente -----
create or replace function aprobar_horas(p_sede text, p_semana date)
returns integer language plpgsql security definer set search_path = public as $$
declare
  quien text := coalesce(auth.jwt() ->> 'email', auth.uid()::text);
  meses text[] := array['Enero','Febrero','Marzo','Abril','Mayo','Junio','Julio','Agosto','Septiembre','Octubre','Noviembre','Diciembre'];
  fin date := p_semana + 6;            -- domingo: el gasto cae en el mes en que termina la semana
  r record; i record; g_id uuid; n integer := 0;
  banco text; cuenta text; metodo text;
begin
  if not exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes','admin_g')) then
    raise exception 'Solo un admin puede aprobar las horas.';
  end if;
  perform set_config('horas.rpc', '1', true);
  delete from horas_semana where sede = p_sede and semana = p_semana and estado <> 'aprobada' and horas = 0;
  for r in select * from horas_semana where sede = p_sede and semana = p_semana and estado <> 'aprobada' loop
    select * into i from instructores where id = r.instructor_id;
    metodo := case when coalesce(i.cuenta_bac,'') <> '' then 'bac'
                   when coalesce(i.cuenta_otro,'') <> '' then 'otro_banco'
                   when coalesce(i.sinpe_movil,'') <> '' then 'sinpe' end;
    banco  := case metodo when 'bac' then 'BAC' when 'otro_banco' then i.otro_banco when 'sinpe' then 'SINPE Móvil' end;
    cuenta := case metodo when 'bac' then i.cuenta_bac when 'otro_banco' then i.cuenta_otro when 'sinpe' then i.sinpe_movil end;
    insert into gastos (sede, categoria, fecha_clase, mes, mes_orden, emisor, instructor_id, documento_cobro, monto,
                        metodo_pago, banco_pago, cuenta_pago, created_by, origen, emisor_cedula, pago_tipo, dia_pago,
                        cargado_at, detalle_clases)
    values (r.sede, 'instructores_planta', fin, meses[extract(month from fin)::int] || ' ' || extract(year from fin),
            to_char(fin, 'YYYY-MM'), i.nombre, i.id, 'Planilla por horas', r.horas * r.tarifa - r.deduccion,
            metodo, banco, cuenta, quien, 'horas', i.cedula, 'transferencia', p_semana + 11, now(),
            jsonb_build_array(jsonb_build_object('tipo', r.tipo, 'cantidad', r.horas, 'unidad', 'h', 'tarifa', r.tarifa,
              'subtotal', r.horas * r.tarifa, 'deduccion', r.deduccion, 'semana', r.semana, 'dias', r.dias, 'nota', r.nota)))
    returning id into g_id;
    update horas_semana set estado = 'aprobada', aprobado_por = quien, aprobado_at = now(), gasto_id = g_id where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- 5) Reabrir una semana aprobada (si todavía no se pagó) ---------------------
create or replace function reabrir_horas(p_sede text, p_semana date)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes','admin_g')) then
    raise exception 'Solo un admin puede reabrir una semana.';
  end if;
  if exists (select 1 from horas_semana h join gastos g on g.id = h.gasto_id
             where h.sede = p_sede and h.semana = p_semana and g.pagado_at is not null) then
    raise exception 'Ya hay pagos marcados de esta semana. Desmárquelos en «Pago de la semana» antes de reabrir.';
  end if;
  perform set_config('horas.rpc', '1', true);
  delete from gastos where id in (select gasto_id from horas_semana where sede = p_sede and semana = p_semana and gasto_id is not null);
  update horas_semana set estado = 'enviada', aprobado_por = null, aprobado_at = null, gasto_id = null
   where sede = p_sede and semana = p_semana and estado = 'aprobada';
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function aprobar_horas(text, date) from anon;
revoke execute on function reabrir_horas(text, date) from anon;

-- Comprobación
select tipo, monto from hora_tarifas order by tipo;
