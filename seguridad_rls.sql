-- ══════════════════════════════════════════════════════════════════════════
--  SEGURIDAD — activar RLS en user_roles, gym_snapshots y plan_prices
--  Correr UNA vez en el SQL editor de Supabase. Se puede repetir sin problema.
--
--  Estas tres tablas tenían la seguridad por filas DESACTIVADA: cualquiera con
--  la llave pública (que viaja dentro de cada página) podía leer, cambiar o
--  borrar todo, incluso sin iniciar sesión — por ejemplo, darse rol de admin.
--  Además tenían reglas "anon_all" que daban acceso total a visitantes.
--
--  Quién usa cada tabla en la app (revisado en el código):
--    user_roles     → cada página lee SU propia fila al entrar; index y movil
--                     leen la lista de usuarios (solo administradores). Ninguna
--                     página escribe: lo hacen crear-usuario y set_user_sedes,
--                     que corren con permisos de servidor y no les afecta RLS.
--    gym_snapshots  → escriben index y nat (administradores); leen además
--                     caja, comparativa, sedes, otros y movil.
--    plan_prices    → escriben index y nat (administradores); leen caja,
--                     comparativa, metas, index y nat.
-- ══════════════════════════════════════════════════════════════════════════

-- ── Función auxiliar: el rol de quien hace la consulta ──────────────────────
-- Las reglas de user_roles no pueden consultar user_roles directamente (eso da
-- "infinite recursion detected in policy"; probablemente por eso se apagó RLS).
-- Esta función lee el rol con permisos de su dueño, sin pasar por las reglas.
create or replace function public.mi_rol()
returns text
language sql stable security definer set search_path = public
as $$ select role from public.user_roles where id = auth.uid() $$;

revoke all on function public.mi_rol() from public;
grant execute on function public.mi_rol() to authenticated;

-- ── user_roles ──────────────────────────────────────────────────────────────
drop policy if exists admin_all       on user_roles;
drop policy if exists "read own role" on user_roles;
drop policy if exists read_own        on user_roles;
drop policy if exists user_roles_select on user_roles;
drop policy if exists user_roles_admin  on user_roles;

-- Cada usuario ve su propia fila; los administradores ven todas
create policy user_roles_select on user_roles
  for select to authenticated
  using (id = auth.uid() or public.mi_rol() in ('admin','admin_sedes','admin_g'));

-- Crear / cambiar / borrar filas: solo admin y admin_sedes (nadie se puede
-- subir el rol a sí mismo)
create policy user_roles_admin on user_roles
  for all to authenticated
  using      (public.mi_rol() in ('admin','admin_sedes'))
  with check (public.mi_rol() in ('admin','admin_sedes'));

alter table user_roles enable row level security;

-- ── gym_snapshots ───────────────────────────────────────────────────────────
drop policy if exists "auth users can insert snapshots" on gym_snapshots;
drop policy if exists "auth users can read snapshots"   on gym_snapshots;
drop policy if exists "auth users can delete snapshots" on gym_snapshots;
drop policy if exists anon_all                          on gym_snapshots;
drop policy if exists snapshots_select on gym_snapshots;
drop policy if exists snapshots_insert on gym_snapshots;
drop policy if exists snapshots_update on gym_snapshots;
drop policy if exists snapshots_delete on gym_snapshots;

-- Leer: roles que usan reportes o caja (no instructor ni empleado: traen datos
-- de clientes que no necesitan)
create policy snapshots_select on gym_snapshots
  for select to authenticated
  using (public.mi_rol() in ('admin','admin_sedes','admin_g','colaborador','recepcion','admin_sucursal','coordinador'));

create policy snapshots_insert on gym_snapshots
  for insert to authenticated
  with check (public.mi_rol() in ('admin','admin_sedes','admin_g'));

create policy snapshots_update on gym_snapshots
  for update to authenticated
  using      (public.mi_rol() in ('admin','admin_sedes','admin_g'))
  with check (public.mi_rol() in ('admin','admin_sedes','admin_g'));

create policy snapshots_delete on gym_snapshots
  for delete to authenticated
  using (public.mi_rol() in ('admin','admin_sedes'));

alter table gym_snapshots enable row level security;

-- ── plan_prices ─────────────────────────────────────────────────────────────
drop policy if exists anon_all on plan_prices;
drop policy if exists plan_prices_select on plan_prices;
drop policy if exists plan_prices_insert on plan_prices;
drop policy if exists plan_prices_update on plan_prices;
drop policy if exists plan_prices_delete on plan_prices;

create policy plan_prices_select on plan_prices
  for select to authenticated
  using (public.mi_rol() in ('admin','admin_sedes','admin_g','colaborador','recepcion','admin_sucursal','coordinador'));

create policy plan_prices_insert on plan_prices
  for insert to authenticated
  with check (public.mi_rol() in ('admin','admin_sedes','admin_g'));

create policy plan_prices_update on plan_prices
  for update to authenticated
  using      (public.mi_rol() in ('admin','admin_sedes','admin_g'))
  with check (public.mi_rol() in ('admin','admin_sedes','admin_g'));

create policy plan_prices_delete on plan_prices
  for delete to authenticated
  using (public.mi_rol() in ('admin','admin_sedes'));

alter table plan_prices enable row level security;

-- ── Visitantes sin sesión: sin acceso a estas tablas ────────────────────────
revoke all on user_roles, gym_snapshots, plan_prices from anon;

-- ── Comprobación ────────────────────────────────────────────────────────────
-- Las tres deben salir con rls_activo = true y sin reglas "anon_all".
select c.relname as tabla, c.relrowsecurity as rls_activo,
       string_agg(p.policyname || ' (' || p.cmd || ')', ', ' order by p.policyname) as reglas
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
left join pg_policies p on p.schemaname = 'public' and p.tablename = c.relname
where n.nspname = 'public' and c.relname in ('user_roles','gym_snapshots','plan_prices')
group by c.relname, c.relrowsecurity
order by c.relname;
