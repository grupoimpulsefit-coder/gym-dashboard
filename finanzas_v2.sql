-- ══════════════════════════════════════════════════════════════════════════
--  FINANZAS v2 — correr DESPUÉS de finanzas.sql. Se puede repetir sin problema.
--
--  1. Finanzas COMPARTIDAS: las cuentas del mismo grupo (fin_duenos.grupo)
--     ven y registran en los mismos datos. Cada fila guarda quién la registró.
--  2. Diezmo único de 25 % (ya no se separa diezmo / primicia / segundo diezmo
--     ni hay 7 rubros). Disponible = 75 %.
--  3. Préstamos (presté / me prestaron) con abonos parciales o totales.
--  4. Arrastre semanal: lo que sobra o falta en una semana pasa a la siguiente
--     (fin_semanas).
--
--  Para compartir con otra cuenta (desde este SQL editor):
--    update fin_duenos set grupo = (select grupo from fin_duenos d join auth.users u
--                                    on u.id = d.user_id where u.email = 'cuenta-existente@x.com')
--    where user_id = (select id from auth.users where email = 'cuenta-nueva@x.com');
-- ══════════════════════════════════════════════════════════════════════════

-- ── 1. Grupo compartido ─────────────────────────────────────────────────────
alter table fin_duenos add column if not exists grupo  uuid not null default gen_random_uuid();
alter table fin_duenos add column if not exists nombre text;

-- ¿La fila de p_owner es de alguien de mi grupo? (incluye a uno mismo)
create or replace function public.fin_comparte(p_owner uuid)
returns boolean
language sql stable security definer set search_path = public
as $$ select exists (select 1 from fin_duenos a join fin_duenos b on b.grupo = a.grupo
                     where a.user_id = auth.uid() and b.user_id = p_owner) $$;
revoke all on function public.fin_comparte(uuid) from public, anon;
grant execute on function public.fin_comparte(uuid) to authenticated;

-- Miembros de mi grupo, con su nombre (para mostrar quién registró qué)
create or replace function public.fin_miembros()
returns table (user_id uuid, nombre text)
language sql stable security definer set search_path = public
as $$ select b.user_id, coalesce(b.nombre, '') from fin_duenos a join fin_duenos b on b.grupo = a.grupo
      where a.user_id = auth.uid() $$;
revoke all on function public.fin_miembros() from public, anon;
grant execute on function public.fin_miembros() to authenticated;

-- ── 2. Diezmo único de 25 %, sin rubros ─────────────────────────────────────
alter table fin_ingresos drop column if exists disponible;
alter table fin_ingresos drop column if exists primicia;
alter table fin_ingresos drop column if exists segundo_diezmo;
alter table fin_ingresos drop column if exists diezmo;
alter table fin_ingresos add column diezmo     numeric(14,2) generated always as (round(monto * 0.25, 2)) stored;
alter table fin_ingresos add column disponible numeric(14,2) generated always as (monto - round(monto * 0.25, 2)) stored;
alter table fin_gastos drop column if exists rubro;
alter table fin_config drop column if exists rubros;

-- La categorización usa las palabras de todo el grupo. Corre como dueño de la
-- función (no hay acceso a fin_duenos desde la app) y no se puede llamar por RPC.
drop function if exists public.fin_categorizar(uuid, text);
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
      ('repuesto','carro'),('repuestos','carro'),('bateria','carro'),('seguro del carro','carro')
    ) d(p, c)
    ) x order by prio, length(palabra) desc
  loop
    if position(fin_normalizar(r.palabra) in t) > 0 then new.categoria := r.categoria; return new; end if;
  end loop;
  return new;
end;
$$;
revoke all on function public.fin_gastos_categoria() from public, anon, authenticated;

-- ── 3. Préstamos y abonos ───────────────────────────────────────────────────
--  tipo 'preste'       → yo le presté a alguien: sale plata; los abonos entran.
--  tipo 'me_prestaron' → alguien me prestó: entra plata; los abonos salen.
--  afecta_saldo = false → solo se lleva el control, no toca el disponible.
create table if not exists fin_prestamos (
  id           uuid primary key default gen_random_uuid(),
  owner        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  tipo         text not null check (tipo in ('preste','me_prestaron')),
  persona      text not null,
  monto        numeric(14,2) not null check (monto > 0),
  fecha        date not null default current_date,
  semana       date generated always as (fecha - (extract(isodow from fecha)::int - 1)) stored,
  descripcion  text,
  afecta_saldo boolean not null default true,
  created_at   timestamptz default now()
);
create table if not exists fin_prestamo_pagos (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  prestamo_id uuid not null references fin_prestamos(id) on delete cascade,
  fecha       date not null default current_date,
  semana      date generated always as (fecha - (extract(isodow from fecha)::int - 1)) stored,
  monto       numeric(14,2) not null check (monto > 0),
  nota        text,
  created_at  timestamptz default now()
);
create index if not exists fin_prestamo_pagos_prestamo on fin_prestamo_pagos (prestamo_id);

-- Un abono no puede pasarse del saldo, ni ir a un préstamo de otro grupo
create or replace function public.fin_pago_guard()
returns trigger language plpgsql security definer set search_path = public
as $$
declare p fin_prestamos; pagado numeric;
begin
  select * into p from fin_prestamos where id = new.prestamo_id for update;
  if not exists (select 1 from fin_duenos a join fin_duenos b on b.grupo = a.grupo
                 where a.user_id = new.owner and b.user_id = p.owner) then
    raise exception 'Préstamo no encontrado';
  end if;
  select coalesce(sum(monto), 0) into pagado from fin_prestamo_pagos
   where prestamo_id = new.prestamo_id and id <> new.id;
  if pagado + new.monto > p.monto then
    raise exception 'El abono (%) es mayor que el saldo pendiente (%)', new.monto, p.monto - pagado;
  end if;
  return new;
end;
$$;
revoke all on function public.fin_pago_guard() from public, anon, authenticated;
drop trigger if exists fin_pago_guard on fin_prestamo_pagos;
create trigger fin_pago_guard before insert or update on fin_prestamo_pagos
  for each row execute function public.fin_pago_guard();

-- ── 4. Resumen por semana con arrastre ──────────────────────────────────────
--  queda = lo que viene de la semana anterior (sobrante o faltante)
--          + disponible + préstamos (neto) − gastos
--  p_miembros: solo para la Edge Function (service_role). Desde la app se deja
--  en null y la seguridad por filas ya limita a su grupo.
create or replace function public.fin_semanas(p_miembros uuid[] default null)
returns table (semana date, ingresos numeric, diezmo numeric, disponible numeric,
               gastos numeric, prestamos numeric, anterior numeric, queda numeric)
language sql stable set search_path = public
as $$
  with mov as (
    select i.semana, i.monto as ing, i.diezmo as diez, i.disponible as disp, 0::numeric as gas, 0::numeric as pre
      from fin_ingresos i where p_miembros is null or i.owner = any(p_miembros)
    union all
    select g.semana, 0, 0, 0, g.monto, 0
      from fin_gastos g where p_miembros is null or g.owner = any(p_miembros)
    union all
    select p.semana, 0, 0, 0, 0, case when p.tipo = 'me_prestaron' then p.monto else -p.monto end
      from fin_prestamos p where p.afecta_saldo and (p_miembros is null or p.owner = any(p_miembros))
    union all
    select a.semana, 0, 0, 0, 0, case when p.tipo = 'preste' then a.monto else -a.monto end
      from fin_prestamo_pagos a join fin_prestamos p on p.id = a.prestamo_id
     where p.afecta_saldo and (p_miembros is null or p.owner = any(p_miembros))
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
           coalesce(sum(m.pre), 0)  as prestamos
      from rango r left join mov m on m.semana = r.semana
     group by r.semana
  )
  select semana, ingresos, diezmo, disponible, gastos, prestamos,
         coalesce(sum(disponible + prestamos - gastos) over (order by semana rows between unbounded preceding and 1 preceding), 0),
         sum(disponible + prestamos - gastos) over (order by semana)
    from sem
   order by semana
$$;
revoke all on function public.fin_semanas(uuid[]) from public, anon;
grant execute on function public.fin_semanas(uuid[]) to authenticated;

-- ── Seguridad por filas: todo el grupo ve y edita lo del grupo ──────────────
do $$
declare t text;
begin
  foreach t in array array['fin_config','fin_ingresos','fin_gastos','fin_reglas','fin_prestamos','fin_prestamo_pagos'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists solo_dueno on %I', t);
    execute format('drop policy if exists grupo on %I', t);
    execute format('create policy grupo on %I for all to authenticated
                      using (public.fin_comparte(owner))
                      with check (public.fin_comparte(owner))', t);
    execute format('revoke all on %I from anon', t);
  end loop;
end $$;
