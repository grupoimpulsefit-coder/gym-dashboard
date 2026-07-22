-- Tabla de costos por producto para el reporte otros.html
-- Ejecutar UNA sola vez en Supabase → SQL Editor.

create table if not exists public.product_costs (
  producto    text primary key,
  categoria   text,
  costo       numeric not null default 0,
  updated_at  timestamptz default now()
);

alter table public.product_costs enable row level security;

-- Lectura: cualquier sesión autenticada (y la clave anon usada por la app)
drop policy if exists product_costs_select on public.product_costs;
create policy product_costs_select on public.product_costs
  for select using (true);

-- Escritura (insert/update/delete): usuarios autenticados
drop policy if exists product_costs_write on public.product_costs;
create policy product_costs_write on public.product_costs
  for all to authenticated using (true) with check (true);

grant select on public.product_costs to anon, authenticated;
grant insert, update, delete on public.product_costs to authenticated;
