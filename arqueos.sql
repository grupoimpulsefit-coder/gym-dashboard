-- ════════════════════════════════════════════════════════════════════════
--  Arqueos de inventario (conteo físico vs sistema desde la app móvil /movil)
--  Registro para auditoría. NO cambia el stock: la app ofrece "Aplicar conteo"
--  como paso aparte (actualiza inventario.cantidad y marca ajustado=true).
--  Correr UNA vez en Supabase → SQL Editor.
-- ════════════════════════════════════════════════════════════════════════

create table if not exists arqueos_inventario (
  id              uuid primary key default gen_random_uuid(),
  sede            text not null,
  fecha           date not null,                 -- fecha local del arqueo (la manda la app)
  items           jsonb not null,                -- { producto: { id, sistema, contado, dif, precio } } (solo lo contado)
  productos       int default 0,                 -- productos en inventario al momento del arqueo
  contados        int default 0,                 -- cuántos se contaron (puede ser parcial)
  con_diferencia  int default 0,
  unidades_dif    numeric default 0,             -- suma de (contado − sistema)
  valor_dif       numeric default 0,             -- suma de (contado − sistema) × precio
  ajustado        boolean default false,         -- true si se aplicó el conteo al sistema
  nota            text,
  created_by      text,
  created_at      timestamptz default now()
);
create index if not exists arqueos_sede_fecha_idx on arqueos_inventario (sede, fecha desc, created_at desc);

alter table arqueos_inventario enable row level security;

-- Admins (todas las sedes): crear, ver y marcar como aplicado
drop policy if exists arqueos_admin on arqueos_inventario;
create policy arqueos_admin on arqueos_inventario
  for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes','admin_g')))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes','admin_g')));

-- Admin de sucursal: solo su sede (o sus sedes_extra)
drop policy if exists arqueos_sucursal on arqueos_inventario;
create policy arqueos_sucursal on arqueos_inventario
  for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role = 'admin_sucursal'
          and (ur.sede = arqueos_inventario.sede or arqueos_inventario.sede = any(ur.sedes_extra))))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role = 'admin_sucursal'
          and (ur.sede = arqueos_inventario.sede or arqueos_inventario.sede = any(ur.sedes_extra))));
