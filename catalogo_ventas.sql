-- ══════════════════════════════════════════════════════════════════════════
--  CATÁLOGO DE VENTAS POR SEDE — qué es cada producto del informe de ventas
--  Correr UNA vez en el SQL editor de Supabase. Se puede repetir sin problema.
--
--  Cuando recepción carga "Ventas por Producto" en caja.html y aparece un
--  producto que la sede no tiene registrado (ni en plan_prices, ni en
--  inventario, ni aquí), la página pregunta qué es y lo guarda en esta tabla:
--    tipo = 'plan'     → membresía
--    tipo = 'clase'    → clase suelta / sesión
--    tipo = 'producto' → minita / mercadería
--  Esta decisión manda sobre la regla por nombre en caja, index y nat.
--  producto_norm: minúsculas, sin tildes, sin la cantidad final "(3)".
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists catalogo_ventas (
  sede          text not null,
  producto_norm text not null,
  producto      text not null,
  tipo          text not null check (tipo in ('plan','clase','producto')),
  updated_by    text,
  updated_at    timestamptz not null default now(),
  primary key (sede, producto_norm)
);

alter table catalogo_ventas enable row level security;

-- Ver: cualquier usuario autenticado (lo usan caja, index y nat para clasificar)
drop policy if exists catalogo_select on catalogo_ventas;
create policy catalogo_select on catalogo_ventas
  for select to authenticated using (true);

-- Crear / cambiar: administradores en cualquier sede; personal de sede en la suya
-- (o en sus sedes_extra)
drop policy if exists catalogo_insert on catalogo_ventas;
create policy catalogo_insert on catalogo_ventas
  for insert to authenticated
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador')
             and (ur.sede = catalogo_ventas.sede or catalogo_ventas.sede = any(ur.sedes_extra))))));

drop policy if exists catalogo_update on catalogo_ventas;
create policy catalogo_update on catalogo_ventas
  for update to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador')
             and (ur.sede = catalogo_ventas.sede or catalogo_ventas.sede = any(ur.sedes_extra))))))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador')
             and (ur.sede = catalogo_ventas.sede or catalogo_ventas.sede = any(ur.sedes_extra))))));

-- Borrar: solo administradores
drop policy if exists catalogo_delete on catalogo_ventas;
create policy catalogo_delete on catalogo_ventas
  for delete to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
                 and ur.role in ('admin','admin_sedes','admin_g')));

-- Sella quién y cuándo
create or replace function catalogo_ventas_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.updated_by := coalesce(auth.jwt() ->> 'email', new.updated_by);
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists catalogo_ventas_guard_trg on catalogo_ventas;
create trigger catalogo_ventas_guard_trg
  before insert or update on catalogo_ventas
  for each row execute function catalogo_ventas_guard();

-- Comprobación: deberían aparecer las 4 políticas
select policyname, cmd from pg_policies where tablename = 'catalogo_ventas' order by policyname;
