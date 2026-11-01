-- ══════════════════════════════════════════════════════════════════════════
--  CLIENTES AUTORIZADOS POR PROMO
--  Correr UNA vez en el SQL editor de Supabase. Se puede repetir sin problema.
--
--  Algunas promos (código "(Promo: X)" en el nombre del plan del informe de
--  Ventas por Producto) son solo para una lista de clientes. Al subir el
--  informe, index.html avisa si alguien que NO está en la lista pagó con ese
--  código. Promos sin lista aquí no se revisan. La lista se ve, se descarga y
--  se edita en la pestaña "Promos" de index.html.
--  promo y cliente_norm van en minúsculas, sin tildes ni espacios dobles
--  (igual que normName() de index.html); promo_nombre es como se muestra.
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists promo_clientes (
  id            bigint generated always as identity primary key,
  sede          text not null,
  promo         text not null,
  cliente       text not null,
  cliente_norm  text not null,
  created_by    text,
  created_at    timestamptz not null default now(),
  unique (sede, promo, cliente_norm)
);
alter table promo_clientes
  add column if not exists promo_nombre text,
  add column if not exists pin          text,
  add column if not exists telefono     text,
  add column if not exists plan         text,
  add column if not exists nota         text;

alter table promo_clientes enable row level security;

-- Ver: quien sube el informe (index.html)
drop policy if exists promo_clientes_select on promo_clientes;
create policy promo_clientes_select on promo_clientes
  for select to authenticated using (true);

-- Cambiar: admin y admin_sedes
drop policy if exists promo_clientes_insert on promo_clientes;
create policy promo_clientes_insert on promo_clientes
  for insert to authenticated
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
                      and ur.role in ('admin','admin_sedes')));

drop policy if exists promo_clientes_delete on promo_clientes;
create policy promo_clientes_delete on promo_clientes
  for delete to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
                 and ur.role in ('admin','admin_sedes')));

-- Misma normalización que normName() de index.html
create or replace function promo_norm(t text) returns text
language sql immutable set search_path = '' as $$
  select trim(regexp_replace(
    translate(lower(t), 'áàäéèëíìïóòöúùüñÁÀÄÉÈËÍÌÏÓÒÖÚÙÜÑ', 'aaaeeeiiiooouuunaaaeeeiiiooouuun'),
    '\s+', ' ', 'g'))
$$;

-- Promo fin de año (Natación): los clientes que la compraron en octubre 2026,
-- con el último plan que pagaron y PIN/teléfono del Informe de Usuarios
insert into promo_clientes (sede, promo, promo_nombre, cliente, cliente_norm, pin, telefono, plan, created_by)
select v.sede, 'promo fin de ano', 'Promo fin de año', v.cliente, v.n, u.pin, u.tel, v.plan, 'ventas octubre 2026'
from (
  select distinct on (promo_norm(e->>'Cliente')) 'Natación'::text sede, promo_norm(e->>'Cliente') n,
         trim(regexp_replace(e->>'Cliente', '\s+', ' ', 'g')) cliente,
         trim(regexp_replace(regexp_replace(e->>'Producto', '\(\s*Promo:.*$', ''), '\s+', ' ', 'g')) plan
  from gym_snapshots s, jsonb_array_elements(s.renov_data) e
  where s.sede = 'Natación' and s.mes_orden = '2026-10'
    and e->>'Producto' ~* '\(\s*promo\s*:\s*promo fin de a'
  order by promo_norm(e->>'Cliente'), to_timestamp(e->>'FechaStr', 'DD/MM/YYYY HH12:MI:SS AM') desc
) v
left join (
  select distinct on (promo_norm(u->>'Nombre')) promo_norm(u->>'Nombre') n, u->>'PIN' pin, u->>'Telefono' tel
  from gym_snapshots s, jsonb_array_elements(s.users_data) u
  where s.sede = 'Natación' and s.mes_orden = '2026-11'
  order by promo_norm(u->>'Nombre'), u->>'PIN'
) u on u.n = v.n
on conflict (sede, promo, cliente_norm) do nothing;

update promo_clientes set nota = 'Pagó la promo 2 veces (2/10 y 31/10)'
  where promo = 'promo fin de ano' and pin = '2106' and nota is null;
update promo_clientes set nota = 'Dos cobros iguales el 24/10 con 3 min de diferencia: revisar cobro doble'
  where promo = 'promo fin de ano' and pin = '8609' and nota is null;

-- Comprobación: 74 clientes
select sede, promo_nombre, count(*) from promo_clientes group by 1, 2;
