-- ══════════════════════════════════════════════════════════════════════════
--  FINANZAS v3 — ajustes de saldo. Correr DESPUÉS de finanzas_v2.sql.
--  Se puede repetir sin problema.
--
--  Un ajuste es un movimiento (+ o −) que corrige el saldo de una semana sin
--  tocar ingresos ni gastos: por ejemplo, "dejar la semana pasada en cero" o
--  "lo que tengo hoy es ₡60 000". Se ve en los movimientos y se puede borrar.
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists fin_ajustes (
  id         uuid primary key default gen_random_uuid(),
  owner      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  fecha      date not null default current_date,
  semana     date generated always as (fecha - (extract(isodow from fecha)::int - 1)) stored,
  monto      numeric(14,2) not null check (monto <> 0),
  nota       text,
  created_at timestamptz default now()
);

alter table fin_ajustes enable row level security;
drop policy if exists grupo on fin_ajustes;
create policy grupo on fin_ajustes for all to authenticated
  using (public.fin_comparte(owner)) with check (public.fin_comparte(owner));
revoke all on fin_ajustes from anon;

-- fin_semanas ahora suma los ajustes (cambia el tipo de retorno: hay que borrarla)
drop function if exists public.fin_semanas(uuid[]);
create function public.fin_semanas(p_miembros uuid[] default null)
returns table (semana date, ingresos numeric, diezmo numeric, disponible numeric,
               gastos numeric, prestamos numeric, ajustes numeric, anterior numeric, queda numeric)
language sql stable set search_path = public
as $$
  with mov as (
    select i.semana, i.monto as ing, i.diezmo as diez, i.disponible as disp, 0::numeric as gas, 0::numeric as pre, 0::numeric as aju
      from fin_ingresos i where p_miembros is null or i.owner = any(p_miembros)
    union all
    select g.semana, 0, 0, 0, g.monto, 0, 0
      from fin_gastos g where p_miembros is null or g.owner = any(p_miembros)
    union all
    select p.semana, 0, 0, 0, 0, case when p.tipo = 'me_prestaron' then p.monto else -p.monto end, 0
      from fin_prestamos p where p.afecta_saldo and (p_miembros is null or p.owner = any(p_miembros))
    union all
    select a.semana, 0, 0, 0, 0, case when p.tipo = 'preste' then a.monto else -a.monto end, 0
      from fin_prestamo_pagos a join fin_prestamos p on p.id = a.prestamo_id
     where p.afecta_saldo and (p_miembros is null or p.owner = any(p_miembros))
    union all
    select j.semana, 0, 0, 0, 0, 0, j.monto
      from fin_ajustes j where p_miembros is null or j.owner = any(p_miembros)
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
           coalesce(sum(m.aju), 0)  as ajustes
      from rango r left join mov m on m.semana = r.semana
     group by r.semana
  )
  select semana, ingresos, diezmo, disponible, gastos, prestamos, ajustes,
         coalesce(sum(disponible + prestamos + ajustes - gastos) over (order by semana rows between unbounded preceding and 1 preceding), 0),
         sum(disponible + prestamos + ajustes - gastos) over (order by semana)
    from sem
   order by semana
$$;
revoke all on function public.fin_semanas(uuid[]) from public, anon;
grant execute on function public.fin_semanas(uuid[]) to authenticated;
