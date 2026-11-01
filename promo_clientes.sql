-- ══════════════════════════════════════════════════════════════════════════
--  CLIENTES AUTORIZADOS POR PROMO
--  Correr UNA vez en el SQL editor de Supabase. Se puede repetir sin problema.
--
--  Algunas promos (código "(Promo: X)" en el nombre del plan del informe de
--  Ventas por Producto) son solo para una lista de clientes. Al subir el
--  informe, index.html avisa si alguien que NO está en la lista pagó con ese
--  código. Promos sin lista aquí no se revisan.
--  promo y cliente_norm van en minúsculas, sin tildes ni espacios dobles
--  (igual que normName() de index.html).
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

-- Promo fin de año (Natación): los clientes que la compraron en octubre 2026
insert into promo_clientes (sede, promo, cliente, cliente_norm, created_by)
select distinct on (promo_norm(e->>'Cliente'))
       'Natación', 'promo fin de ano', trim(regexp_replace(e->>'Cliente', '\s+', ' ', 'g')),
       promo_norm(e->>'Cliente'), 'ventas octubre 2026'
from gym_snapshots s, jsonb_array_elements(s.renov_data) e
where s.sede = 'Natación' and s.mes_orden = '2026-10'
  and e->>'Producto' ~* '\(\s*promo\s*:\s*promo fin de a'
on conflict (sede, promo, cliente_norm) do nothing;

-- Comprobación: 74 clientes
select sede, promo, count(*) from promo_clientes group by 1, 2;
