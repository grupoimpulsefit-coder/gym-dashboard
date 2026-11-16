-- ══════════════════════════════════════════════════════════════════════════
--  FINANZAS PERSONALES — ingresos semanales, diezmo y gastos (página /finanzas)
--  Correr UNA vez en el SQL editor de Supabase. Se puede repetir sin problema.
--
--  Privacidad: estas tablas NO usan user_roles. Solo las ve la cuenta cuyo id
--  esté en fin_duenos, y cada fila solo la ve su dueño (owner = auth.uid()).
--  Ningún rol del gimnasio (admin, admin_sedes, …) tiene acceso, y nadie puede
--  agregarse a fin_duenos desde la app: solo desde este SQL editor.
--  (Quien tenga acceso al panel de Supabase / service_role sí puede ver todo:
--   eso es así para cualquier tabla de la base.)
--
--  Pasos:
--    1. Authentication → Users → "Add user": cree una cuenta con su correo
--       personal (NO con crear-usuario, así no queda en user_roles ni en la
--       lista de usuarios del gimnasio).
--    2. Corra este archivo.
--    3. Corra (con su correo):
--         insert into fin_duenos (user_id)
--         select id from auth.users where email = 'su-correo@ejemplo.com'
--         on conflict do nothing;
-- ══════════════════════════════════════════════════════════════════════════

-- ── Lista de dueños (solo editable desde el SQL editor) ─────────────────────
create table if not exists fin_duenos (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz default now()
);
alter table fin_duenos enable row level security;      -- sin reglas = nadie desde la app
revoke all on fin_duenos from anon, authenticated;

create or replace function public.fin_es_dueno()
returns boolean
language sql stable security definer set search_path = public
as $$ select exists (select 1 from fin_duenos where user_id = auth.uid()) $$;
revoke all on function public.fin_es_dueno() from public, anon;
grant execute on function public.fin_es_dueno() to authenticated;

-- ── Configuración: nombres de los 7 rubros y vínculo con Telegram ───────────
create table if not exists fin_config (
  owner            uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  rubros           text[] not null default array['Rubro 1','Rubro 2','Rubro 3','Rubro 4','Rubro 5','Rubro 6','Rubro 7']
                   check (cardinality(rubros) = 7),
  telegram_chat_id bigint unique,
  telegram_codigo  text unique,          -- código de un solo uso para vincular el chat
  updated_at       timestamptz default now()
);

-- ── Ingresos: el reparto se calcula solo ────────────────────────────────────
--  10 % diezmo · 5 % primicia · 10 % segundo diezmo (÷ 7 rubros) · 75 % disponible
create table if not exists fin_ingresos (
  id             uuid primary key default gen_random_uuid(),
  owner          uuid not null default auth.uid() references auth.users(id) on delete cascade,
  fecha          date not null default current_date,
  semana         date generated always as (fecha - (extract(isodow from fecha)::int - 1)) stored,  -- lunes
  monto          numeric(14,2) not null check (monto > 0),
  descripcion    text,
  diezmo         numeric(14,2) generated always as (round(monto * 0.10, 2)) stored,
  primicia       numeric(14,2) generated always as (round(monto * 0.05, 2)) stored,
  segundo_diezmo numeric(14,2) generated always as (round(monto * 0.10, 2)) stored,
  disponible     numeric(14,2) generated always as
                   (monto - round(monto * 0.10, 2) - round(monto * 0.05, 2) - round(monto * 0.10, 2)) stored,
  entregado      boolean not null default false,   -- diezmo + primicia ya entregados
  origen         text not null default 'app',
  created_at     timestamptz default now()
);
create index if not exists fin_ingresos_owner_fecha on fin_ingresos (owner, fecha desc);

-- ── Gastos ──────────────────────────────────────────────────────────────────
--  rubro null = sale del 75 % disponible; 1..7 = sale de ese rubro del segundo diezmo
create table if not exists fin_gastos (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  fecha       date not null default current_date,
  semana      date generated always as (fecha - (extract(isodow from fecha)::int - 1)) stored,
  monto       numeric(14,2) not null check (monto > 0),
  descripcion text,
  categoria   text,                                  -- vacía → se detecta sola (trigger)
  rubro       smallint check (rubro between 1 and 7),
  origen      text not null default 'app',
  created_at  timestamptz default now()
);
create index if not exists fin_gastos_owner_fecha on fin_gastos (owner, fecha desc);

-- ── Palabras propias para categorizar (ej. "pricesmart" → comida) ────────────
create table if not exists fin_reglas (
  owner     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  palabra   text not null,
  categoria text not null,
  primary key (owner, palabra)
);

-- ── Categorización automática ───────────────────────────────────────────────
--  Busca palabras completas en la descripción: primero las suyas, luego estas.
create or replace function public.fin_normalizar(t text)
returns text language sql immutable set search_path = public
as $$ select ' ' || btrim(regexp_replace(translate(lower(coalesce(t, '')), 'áéíóúüñ', 'aeiouun'), '[^a-z0-9]+', ' ', 'g')) || ' ' $$;

create or replace function public.fin_categorizar(p_owner uuid, p_texto text)
returns text
language plpgsql stable set search_path = public
as $$
declare
  t text := fin_normalizar(p_texto);
  r record;
begin
  if btrim(t) = '' then return 'otros'; end if;
  for r in
    select * from (
    select palabra, categoria, 0 as prio from fin_reglas where owner = p_owner
    union all
    select p, c, 1 from (values
      -- comida
      ('uber eats','comida'),('didi food','comida'),('rappi','comida'),('comida','comida'),('super','comida'),
      ('supermercado','comida'),('walmart','comida'),('maxi pali','comida'),('maxipali','comida'),('pali','comida'),
      ('masxmenos','comida'),('mas x menos','comida'),('automercado','comida'),('auto mercado','comida'),
      ('fresh market','comida'),('pricesmart','comida'),('megasuper','comida'),('perimercados','comida'),
      ('almuerzo','comida'),('desayuno','comida'),('cena','comida'),('restaurante','comida'),('soda','comida'),
      ('cafe','comida'),('pizza','comida'),('hamburguesa','comida'),('pollo','comida'),('mcdonalds','comida'),
      ('kfc','comida'),('subway','comida'),('tacos','comida'),('panaderia','comida'),('pan','comida'),
      ('verduleria','comida'),('carniceria','comida'),('feria','comida'),('pulperia','comida'),('mercado','comida'),
      ('frutas','comida'),('verduras','comida'),('carne','comida'),('leche','comida'),('huevos','comida'),
      -- alquiler
      ('alquiler','alquiler'),('renta','alquiler'),('arriendo','alquiler'),('apartamento','alquiler'),('apto','alquiler'),
      -- aplicaciones / suscripciones
      ('aplicaciones','aplicaciones'),('aplicacion','aplicaciones'),('app','aplicaciones'),('apps','aplicaciones'),
      ('suscripcion','aplicaciones'),('netflix','aplicaciones'),('spotify','aplicaciones'),('disney','aplicaciones'),
      ('hbo','aplicaciones'),('prime video','aplicaciones'),('amazon prime','aplicaciones'),('youtube','aplicaciones'),
      ('icloud','aplicaciones'),('google one','aplicaciones'),('chatgpt','aplicaciones'),('claude','aplicaciones'),
      ('office','aplicaciones'),('microsoft','aplicaciones'),('canva','aplicaciones'),('adobe','aplicaciones'),
      ('crunchyroll','aplicaciones'),('xbox','aplicaciones'),('playstation','aplicaciones'),('apple','aplicaciones'),
      -- carro
      ('carro','carro'),('gasolina','carro'),('gasolinera','carro'),('combustible','carro'),('diesel','carro'),
      ('marchamo','carro'),('riteve','carro'),('taller','carro'),('mecanico','carro'),('llanta','carro'),
      ('llantas','carro'),('aceite','carro'),('lavacar','carro'),('parqueo','carro'),('peaje','carro'),
      ('repuesto','carro'),('repuestos','carro'),('bateria','carro'),('seguro del carro','carro')
    ) d(p, c)
    ) x order by prio, length(palabra) desc
  loop
    if position(fin_normalizar(r.palabra) in t) > 0 then return r.categoria; end if;
  end loop;
  return 'otros';
end;
$$;

create or replace function public.fin_gastos_categoria()
returns trigger language plpgsql set search_path = public
as $$
begin
  if new.categoria is null or btrim(new.categoria) = '' then
    new.categoria := fin_categorizar(new.owner, new.descripcion);
  else
    new.categoria := lower(btrim(new.categoria));
  end if;
  return new;
end;
$$;
drop trigger if exists fin_gastos_categoria on fin_gastos;
create trigger fin_gastos_categoria before insert or update on fin_gastos
  for each row execute function public.fin_gastos_categoria();

-- ── Seguridad por filas: solo el dueño, y solo si está en fin_duenos ─────────
do $$
declare t text;
begin
  foreach t in array array['fin_config','fin_ingresos','fin_gastos','fin_reglas'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists solo_dueno on %I', t);
    execute format('create policy solo_dueno on %I for all to authenticated
                      using (owner = auth.uid() and public.fin_es_dueno())
                      with check (owner = auth.uid() and public.fin_es_dueno())', t);
    execute format('revoke all on %I from anon', t);
  end loop;
end $$;

-- ── Comprobación: las 5 tablas con rls_activo = true ────────────────────────
select c.relname as tabla, c.relrowsecurity as rls_activo
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname like 'fin\_%' and c.relkind = 'r'
order by 1;
