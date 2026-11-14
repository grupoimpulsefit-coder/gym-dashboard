-- ══════════════════════════════════════════════════════════════════════════
--  FINANZAS v6 — usuarios de un solo fondo (ej. Cucho). Correr DESPUÉS de
--  finanzas_v5.sql. Se puede repetir sin problema.
--
--  Un "usuario de fondo" NO es del grupo: no ve ingresos, gastos de la semana,
--  préstamos, ajustes ni otros fondos. Solo ve SU fondo y puede:
--    · registrar gastos pagados con ese fondo (y borrar los suyos);
--    · enviar plata del fondo al disponible de la semana del grupo (sin diezmo).
--  No puede agregarle plata al fondo (eso lo hace el aporte mensual o el grupo).
--  El grupo ve todo lo que él registra, en el fondo y en los movimientos.
--
--  Para dar acceso (desde este SQL editor; la cuenta se crea antes en
--  Authentication → Users → Add user, con "Auto Confirm User"):
--    insert into fin_fondo_usuarios (fondo_id, user_id)
--    select f.id, u.id from fin_fondos f, auth.users u
--    where f.nombre = 'Cucho' and u.email = 'cucho@finanzas.local';
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists fin_fondo_usuarios (
  fondo_id uuid not null references fin_fondos(id) on delete cascade,
  user_id  uuid not null references auth.users(id) on delete cascade,
  primary key (fondo_id, user_id)
);
alter table fin_fondo_usuarios enable row level security;   -- sin reglas: solo desde el SQL editor
revoke all on fin_fondo_usuarios from anon, authenticated;

-- Fondos a los que tengo acceso como usuario de fondo
create or replace function public.fin_mis_fondos()
returns setof uuid
language sql stable security definer set search_path = public
as $$ select fondo_id from fin_fondo_usuarios where user_id = auth.uid() $$;
revoke all on function public.fin_mis_fondos() from public, anon;
grant execute on function public.fin_mis_fondos() to authenticated;

-- 'grupo' (finanzas completas), 'fondo' (solo su fondo) o null (sin acceso)
create or replace function public.fin_mi_acceso()
returns text
language sql stable security definer set search_path = public
as $$ select case when exists (select 1 from fin_duenos where user_id = auth.uid()) then 'grupo'
                  when exists (select 1 from fin_fondo_usuarios where user_id = auth.uid()) then 'fondo' end $$;
revoke all on function public.fin_mi_acceso() from public, anon;
grant execute on function public.fin_mi_acceso() to authenticated;

-- ── Reglas para el usuario de fondo ─────────────────────────────────────────
drop policy if exists fondo_usuario on fin_fondos;
create policy fondo_usuario on fin_fondos for select to authenticated
  using (id in (select public.fin_mis_fondos()));

drop policy if exists fondo_usuario_ver on fin_fondo_movs;
create policy fondo_usuario_ver on fin_fondo_movs for select to authenticated
  using (fondo_id in (select public.fin_mis_fondos()));
drop policy if exists fondo_usuario_sacar on fin_fondo_movs;
create policy fondo_usuario_sacar on fin_fondo_movs for insert to authenticated     -- solo saca (gasto o envío)
  with check (owner = auth.uid() and monto < 0 and fondo_id in (select public.fin_mis_fondos()));
drop policy if exists fondo_usuario_borrar on fin_fondo_movs;
create policy fondo_usuario_borrar on fin_fondo_movs for delete to authenticated
  using (owner = auth.uid() and fondo_id in (select public.fin_mis_fondos()));

drop policy if exists fondo_usuario on fin_gastos;
create policy fondo_usuario on fin_gastos for all to authenticated
  using (owner = auth.uid() and fondo_id in (select public.fin_mis_fondos()))
  with check (owner = auth.uid() and fondo_id in (select public.fin_mis_fondos()));

-- ── El grupo ve y maneja lo que registran en sus fondos ─────────────────────
drop policy if exists fondo_del_grupo on fin_gastos;
create policy fondo_del_grupo on fin_gastos for all to authenticated
  using (fondo_id is not null and exists (select 1 from fin_fondos f where f.id = fin_gastos.fondo_id and public.fin_comparte(f.owner)))
  with check (fondo_id is not null and exists (select 1 from fin_fondos f where f.id = fin_gastos.fondo_id and public.fin_comparte(f.owner)));
drop policy if exists fondo_del_grupo on fin_fondo_movs;
create policy fondo_del_grupo on fin_fondo_movs for all to authenticated
  using (exists (select 1 from fin_fondos f where f.id = fin_fondo_movs.fondo_id and public.fin_comparte(f.owner)))
  with check (exists (select 1 from fin_fondos f where f.id = fin_fondo_movs.fondo_id and public.fin_comparte(f.owner)));

-- ── Guardia del fondo: también acepta al usuario del fondo ──────────────────
create or replace function public.fin_fondo_guard()
returns trigger language plpgsql security definer set search_path = public
as $$
declare f fin_fondos; saldo numeric;
begin
  select * into f from fin_fondos where id = new.fondo_id for update;
  if not exists (select 1 from fin_duenos a join fin_duenos b on b.grupo = a.grupo
                 where a.user_id = new.owner and b.user_id = f.owner)
     and not exists (select 1 from fin_fondo_usuarios where fondo_id = new.fondo_id and user_id = new.owner) then
    raise exception 'Fondo no encontrado';
  end if;
  select coalesce(sum(monto), 0) into saldo from fin_fondo_movs where fondo_id = new.fondo_id and id <> new.id;
  if saldo + new.monto < 0 then
    if new.gasto_id is not null then
      raise exception 'El fondo % solo tiene % y el gasto es de %', f.nombre, saldo, -new.monto;
    end if;
    raise exception 'El fondo % solo tiene % y se quieren sacar %', f.nombre, saldo, -new.monto;
  end if;
  return new;
end;
$$;
revoke all on function public.fin_fondo_guard() from public, anon, authenticated;

-- ── Aportes mensuales: corre como dueño (el usuario de fondo no puede crear
--    aportes, pero al abrir la página igual se ponen al día) ─────────────────
alter function public.fin_fondos_al_dia() security definer;

-- ── fin_semanas: un envío del fondo cuenta para el grupo dueño del fondo,
--    lo haya hecho quien lo haya hecho ───────────────────────────────────────
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
      from fin_fondo_movs f join fin_fondos fo on fo.id = f.fondo_id
     where f.afecta_saldo and (p_miembros is null or fo.owner = any(p_miembros))
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
