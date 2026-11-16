-- ══════════════════════════════════════════════════════════════════════════
--  FINANZAS v5 — fondos con aporte mensual y gastos pagados desde un fondo.
--  Correr DESPUÉS de finanzas_v4.sql. Se puede repetir sin problema.
--
--  1. Aporte mensual: un fondo puede recibir un monto fijo cada mes (ej. Cucho:
--     ₡40 000 el día 1). No sale del disponible ni paga diezmo. Lo registra
--     fin_fondos_al_dia(), que la página y el bot llaman al abrir (no hace falta
--     cron: si nadie entra en un mes, se pone al día la próxima vez).
--  2. Gastos desde un fondo: fin_gastos.fondo_id. El gasto se descuenta del
--     fondo (movimiento automático) y NO del disponible de la semana. Si el
--     fondo no alcanza, el gasto se rechaza.
--  Pasar plata del fondo a la semana = retiro que vuelve al disponible (v4).
-- ══════════════════════════════════════════════════════════════════════════

-- ── 1. Aporte mensual ───────────────────────────────────────────────────────
alter table fin_fondos add column if not exists aporte_mensual numeric(14,2) check (aporte_mensual > 0);
alter table fin_fondos add column if not exists dia_mes smallint not null default 1 check (dia_mes between 1 and 28);
alter table fin_fondos add column if not exists aporte_desde date;   -- primer mes con aporte (día 1 del mes)

alter table fin_fondo_movs add column if not exists periodo date;     -- mes del aporte automático
create unique index if not exists fin_fondo_movs_periodo on fin_fondo_movs (fondo_id, periodo) where periodo is not null;

-- Registra los aportes mensuales que falten, hasta el mes actual (hora de Costa Rica).
-- Corre con los permisos de quien llama: solo ve los fondos de su grupo.
create or replace function public.fin_fondos_al_dia()
returns integer
language plpgsql set search_path = public
as $$
declare f record; n integer := 0; c integer; hoy date := (now() at time zone 'America/Costa_Rica')::date;
begin
  for f in select * from fin_fondos where aporte_mensual is not null loop
    insert into fin_fondo_movs (owner, fondo_id, fecha, monto, nota, afecta_saldo, periodo)
    select f.owner, f.id, (m + (f.dia_mes - 1) * interval '1 day')::date, f.aporte_mensual, 'aporte mensual', false, m::date
      from generate_series(date_trunc('month', coalesce(f.aporte_desde, f.created_at::date)), date_trunc('month', hoy), interval '1 month') m
     where (m + (f.dia_mes - 1) * interval '1 day')::date <= hoy
    on conflict (fondo_id, periodo) where periodo is not null do nothing;
    get diagnostics c = row_count; n := n + c;
  end loop;
  return n;
end;
$$;
revoke all on function public.fin_fondos_al_dia() from public, anon;
grant execute on function public.fin_fondos_al_dia() to authenticated;

-- ── 2. Gastos pagados desde un fondo ────────────────────────────────────────
alter table fin_gastos add column if not exists fondo_id uuid references fin_fondos(id) on delete restrict;
alter table fin_fondo_movs add column if not exists gasto_id uuid references fin_gastos(id) on delete cascade;
create unique index if not exists fin_fondo_movs_gasto on fin_fondo_movs (gasto_id) where gasto_id is not null;

-- Mantiene el movimiento del fondo igual al gasto (al crear, cambiar o quitar el fondo)
create or replace function public.fin_gasto_fondo_sync()
returns trigger language plpgsql set search_path = public
as $$
begin
  delete from fin_fondo_movs where gasto_id = new.id;
  if new.fondo_id is not null then
    insert into fin_fondo_movs (owner, fondo_id, fecha, monto, nota, afecta_saldo, gasto_id)
    values (new.owner, new.fondo_id, new.fecha, -new.monto, coalesce('gasto: ' || new.descripcion, 'gasto'), false, new.id);
  end if;
  return null;
end;
$$;
revoke all on function public.fin_gasto_fondo_sync() from public, anon, authenticated;
drop trigger if exists fin_gasto_fondo_sync on fin_gastos;
create trigger fin_gasto_fondo_sync after insert or update of fondo_id, monto, fecha, descripcion on fin_gastos
  for each row execute function public.fin_gasto_fondo_sync();

-- El aviso del fondo debe decir "gasto" cuando lo que no alcanza es un gasto
create or replace function public.fin_fondo_guard()
returns trigger language plpgsql security definer set search_path = public
as $$
declare f fin_fondos; saldo numeric;
begin
  select * into f from fin_fondos where id = new.fondo_id for update;
  if not exists (select 1 from fin_duenos a join fin_duenos b on b.grupo = a.grupo
                 where a.user_id = new.owner and b.user_id = f.owner) then
    raise exception 'Fondo no encontrado';
  end if;
  select coalesce(sum(monto), 0) into saldo from fin_fondo_movs where fondo_id = new.fondo_id and id <> new.id;
  if saldo + new.monto < 0 then
    if new.gasto_id is not null then
      raise exception 'El fondo % solo tiene % y el gasto es de %', f.nombre, saldo, -new.monto;
    end if;
    raise exception 'El retiro (%) es mayor que lo que tiene el fondo (%)', -new.monto, saldo;
  end if;
  return new;
end;
$$;
revoke all on function public.fin_fondo_guard() from public, anon, authenticated;

-- ── fin_semanas: los gastos pagados desde un fondo no tocan la semana ──────
drop function if exists public.fin_semanas(uuid[]);
create function public.fin_semanas(p_miembros uuid[] default null)
returns table (semana date, ingresos numeric, diezmo numeric, disponible numeric,
               gastos numeric, prestamos numeric, ajustes numeric, ahorro numeric, anterior numeric, queda numeric)
language sql stable set search_path = public
as $$
  with mov as (
    select i.semana, i.monto as ing, i.diezmo as diez, i.disponible as disp, 0::numeric as gas, 0::numeric as pre,
           0::numeric as aju, 0::numeric as aho
      from fin_ingresos i where p_miembros is null or i.owner = any(p_miembros)
    union all
    select g.semana, 0, 0, 0, g.monto, 0, 0, 0
      from fin_gastos g where g.fondo_id is null and (p_miembros is null or g.owner = any(p_miembros))
    union all
    select p.semana, 0, 0, 0, 0, case when p.tipo = 'me_prestaron' then p.monto else -p.monto end, 0, 0
      from fin_prestamos p where p.afecta_saldo and (p_miembros is null or p.owner = any(p_miembros))
    union all
    select a.semana, 0, 0, 0, 0, case when p.tipo = 'preste' then a.monto else -a.monto end, 0, 0
      from fin_prestamo_pagos a join fin_prestamos p on p.id = a.prestamo_id
     where p.afecta_saldo and (p_miembros is null or p.owner = any(p_miembros))
    union all
    select j.semana, 0, 0, 0, 0, 0, j.monto, 0
      from fin_ajustes j where p_miembros is null or j.owner = any(p_miembros)
    union all
    select f.semana, 0, 0, 0, 0, 0, 0, -f.monto
      from fin_fondo_movs f where f.afecta_saldo and (p_miembros is null or f.owner = any(p_miembros))
  ),
  hoy as (select (now() at time zone 'America/Costa_Rica')::date as d),
  rango as (
    select s::date as semana
      from (select min(semana) as a, max(semana) as b from mov) x,
           hoy,
           generate_series(x.a, greatest(x.b, hoy.d - (extract(isodow from hoy.d)::int - 1)), interval '7 days') s
     where x.a is not null
  ),
  sem as (
    select r.semana,
           coalesce(sum(m.ing), 0)  as ingresos,
           coalesce(sum(m.diez), 0) as diezmo,
           coalesce(sum(m.disp), 0) as disponible,
           coalesce(sum(m.gas), 0)  as gastos,
           coalesce(sum(m.pre), 0)  as prestamos,
           coalesce(sum(m.aju), 0)  as ajustes,
           coalesce(sum(m.aho), 0)  as ahorro
      from rango r left join mov m on m.semana = r.semana
     group by r.semana
  )
  select semana, ingresos, diezmo, disponible, gastos, prestamos, ajustes, ahorro,
         coalesce(sum(disponible + prestamos + ajustes + ahorro - gastos) over (order by semana rows between unbounded preceding and 1 preceding), 0),
         sum(disponible + prestamos + ajustes + ahorro - gastos) over (order by semana)
    from sem
   order by semana
$$;
revoke all on function public.fin_semanas(uuid[]) from public, anon;
grant execute on function public.fin_semanas(uuid[]) to authenticated;
