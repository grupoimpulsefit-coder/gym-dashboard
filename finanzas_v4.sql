-- ══════════════════════════════════════════════════════════════════════════
--  FINANZAS v4 — categorías nuevas y fondos de ahorro. Correr DESPUÉS de
--  finanzas_v3.sql. Se puede repetir sin problema.
--
--  1. Categorías nuevas con palabras automáticas: salud, cuidado personal,
--     servicios y bb (además de comida, alquiler, aplicaciones, carro y otros).
--  2. Fondos de ahorro (ej. "Chloe"): plata apartada que NO está en el
--     disponible de la semana. Un aporte sale del disponible y un retiro
--     vuelve a él (salvo que se marque que no lo mueve, como el saldo inicial).
-- ══════════════════════════════════════════════════════════════════════════

-- ── 1. Categorías ───────────────────────────────────────────────────────────
create or replace function public.fin_gastos_categoria()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  t text := fin_normalizar(new.descripcion);
  r record;
begin
  if new.categoria is not null and btrim(new.categoria) <> '' then
    new.categoria := lower(btrim(new.categoria));
    return new;
  end if;
  new.categoria := 'otros';
  if btrim(t) = '' then return new; end if;
  for r in
    select * from (
    select palabra, categoria, 0 as prio from fin_reglas
     where owner in (select b.user_id from fin_duenos a join fin_duenos b on b.grupo = a.grupo where a.user_id = new.owner)
    union all
    select p, c, 1 from (values
      ('uber eats','comida'),('didi food','comida'),('rappi','comida'),('comida','comida'),('super','comida'),
      ('supermercado','comida'),('walmart','comida'),('maxi pali','comida'),('maxipali','comida'),('pali','comida'),
      ('masxmenos','comida'),('mas x menos','comida'),('automercado','comida'),('auto mercado','comida'),
      ('fresh market','comida'),('pricesmart','comida'),('megasuper','comida'),('perimercados','comida'),
      ('almuerzo','comida'),('desayuno','comida'),('cena','comida'),('restaurante','comida'),('soda','comida'),
      ('cafe','comida'),('pizza','comida'),('hamburguesa','comida'),('pollo','comida'),('mcdonalds','comida'),
      ('kfc','comida'),('subway','comida'),('tacos','comida'),('panaderia','comida'),('pan','comida'),
      ('verduleria','comida'),('carniceria','comida'),('feria','comida'),('pulperia','comida'),('mercado','comida'),
      ('frutas','comida'),('verduras','comida'),('carne','comida'),('leche','comida'),('huevos','comida'),
      ('alquiler','alquiler'),('renta','alquiler'),('arriendo','alquiler'),('apartamento','alquiler'),('apto','alquiler'),
      ('aplicaciones','aplicaciones'),('aplicacion','aplicaciones'),('app','aplicaciones'),('apps','aplicaciones'),
      ('suscripcion','aplicaciones'),('netflix','aplicaciones'),('spotify','aplicaciones'),('disney','aplicaciones'),
      ('hbo','aplicaciones'),('prime video','aplicaciones'),('amazon prime','aplicaciones'),('youtube','aplicaciones'),
      ('icloud','aplicaciones'),('google one','aplicaciones'),('chatgpt','aplicaciones'),('claude','aplicaciones'),
      ('office','aplicaciones'),('microsoft','aplicaciones'),('canva','aplicaciones'),('adobe','aplicaciones'),
      ('crunchyroll','aplicaciones'),('xbox','aplicaciones'),('playstation','aplicaciones'),('apple','aplicaciones'),
      ('carro','carro'),('gasolina','carro'),('gasolinera','carro'),('combustible','carro'),('diesel','carro'),
      ('marchamo','carro'),('riteve','carro'),('taller','carro'),('mecanico','carro'),('llanta','carro'),
      ('llantas','carro'),('aceite','carro'),('lavacar','carro'),('parqueo','carro'),('peaje','carro'),
      ('repuesto','carro'),('repuestos','carro'),('bateria','carro'),('seguro del carro','carro'),
      -- salud
      ('salud','salud'),('farmacia','salud'),('medicina','salud'),('medicinas','salud'),('medicamento','salud'),
      ('pastillas','salud'),('doctor','salud'),('doctora','salud'),('medico','salud'),('clinica','salud'),('hospital','salud'),
      ('ebais','salud'),('consulta','salud'),('dentista','salud'),('odontologo','salud'),('examenes','salud'),
      ('laboratorio','salud'),('optica','salud'),('lentes','salud'),('vacuna','salud'),('fischel','salud'),('sucre','salud'),
      -- cuidado personal
      ('cuidado personal','cuidado personal'),('barberia','cuidado personal'),('barbero','cuidado personal'),
      ('peluqueria','cuidado personal'),('corte de pelo','cuidado personal'),('unas','cuidado personal'),
      ('manicure','cuidado personal'),('pedicure','cuidado personal'),('cejas','cuidado personal'),
      ('maquillaje','cuidado personal'),('shampoo','cuidado personal'),('champu','cuidado personal'),
      ('desodorante','cuidado personal'),('perfume','cuidado personal'),
      ('jabon','cuidado personal'),('cepillo de dientes','cuidado personal'),('pasta de dientes','cuidado personal'),
      -- servicios
      ('servicios','servicios'),('luz','servicios'),('agua','servicios'),('internet','servicios'),('telefono','servicios'),
      ('celular','servicios'),('recarga','servicios'),('kolbi','servicios'),('liberty','servicios'),('claro','servicios'),
      ('tigo','servicios'),('cable','servicios'),('recibo','servicios'),('cnfl','servicios'),
      ('aya','servicios'),('gas de cocina','servicios'),('cilindro','servicios'),
      -- bb
      ('bb','bb'),('bebe','bb'),('panales','bb'),('panitos','bb'),('toallitas','bb'),('formula','bb'),
      ('leche de bebe','bb'),('leche bebe','bb'),('pediatra','bb'),('chupeta','bb'),('pacha','bb'),('guarderia','bb')
    ) d(p, c)
    ) x order by prio, length(palabra) desc
  loop
    if position(fin_normalizar(r.palabra) in t) > 0 then new.categoria := r.categoria; return new; end if;
  end loop;
  return new;
end;
$$;
revoke all on function public.fin_gastos_categoria() from public, anon, authenticated;

-- ── 2. Fondos de ahorro ─────────────────────────────────────────────────────
create table if not exists fin_fondos (
  id         uuid primary key default gen_random_uuid(),
  owner      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  nombre     text not null,
  created_at timestamptz default now()
);
--  monto > 0 = aporte (entra al fondo) · monto < 0 = retiro (sale del fondo)
--  afecta_saldo = true → el aporte sale del disponible / el retiro vuelve a él
create table if not exists fin_fondo_movs (
  id           uuid primary key default gen_random_uuid(),
  owner        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  fondo_id     uuid not null references fin_fondos(id) on delete cascade,
  fecha        date not null default current_date,
  semana       date generated always as (fecha - (extract(isodow from fecha)::int - 1)) stored,
  monto        numeric(14,2) not null check (monto <> 0),
  nota         text,
  afecta_saldo boolean not null default true,
  created_at   timestamptz default now()
);
create index if not exists fin_fondo_movs_fondo on fin_fondo_movs (fondo_id);

-- Un retiro no puede dejar el fondo en negativo, ni moverse a un fondo de otro grupo
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
    raise exception 'El retiro (%) es mayor que lo que tiene el fondo (%)', -new.monto, saldo;
  end if;
  return new;
end;
$$;
revoke all on function public.fin_fondo_guard() from public, anon, authenticated;
drop trigger if exists fin_fondo_guard on fin_fondo_movs;
create trigger fin_fondo_guard before insert or update on fin_fondo_movs
  for each row execute function public.fin_fondo_guard();

do $$
declare t text;
begin
  foreach t in array array['fin_fondos','fin_fondo_movs'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists grupo on %I', t);
    execute format('create policy grupo on %I for all to authenticated
                      using (public.fin_comparte(owner)) with check (public.fin_comparte(owner))', t);
    execute format('revoke all on %I from anon', t);
  end loop;
end $$;

-- fin_semanas: los aportes al ahorro restan del disponible y los retiros suman
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
      from fin_gastos g where p_miembros is null or g.owner = any(p_miembros)
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
