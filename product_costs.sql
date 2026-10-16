-- Tabla de costos por producto para el reporte otros.html
-- Ejecutar en Supabase → SQL Editor, DESPUÉS de seguridad_rls.sql (usa mi_rol()).
-- Se puede repetir sin problema.

create table if not exists public.product_costs (
  producto    text primary key,
  categoria   text,
  costo       numeric not null default 0,
  updated_at  timestamptz default now()
);

alter table public.product_costs enable row level security;

-- Solo administradores leen y cambian costos (otros.html lo abre admin_sedes,
-- siempre con sesión). Antes cualquier sesión podía reescribirlos y los
-- visitantes sin sesión podían leerlos.
drop policy if exists product_costs_select on public.product_costs;
create policy product_costs_select on public.product_costs
  for select to authenticated
  using (public.mi_rol() in ('admin','admin_sedes','admin_g'));

drop policy if exists product_costs_write on public.product_costs;
create policy product_costs_write on public.product_costs
  for all to authenticated
  using      (public.mi_rol() in ('admin','admin_sedes','admin_g'))
  with check (public.mi_rol() in ('admin','admin_sedes','admin_g'));

revoke all on public.product_costs from anon;
grant select, insert, update, delete on public.product_costs to authenticated;
