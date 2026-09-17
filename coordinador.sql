-- ════════════════════════════════════════════════════════════════════════
--  Rol COORDINADOR — solo CONSULTA del inventario
--
--  Se le dan únicamente políticas de SELECT: al no existir políticas de
--  insert/update/delete para este rol, el RLS le niega cualquier cambio
--  aunque intente escribir directo contra la API.
--
--  Alcance de sedes:
--    user_roles.sede = NULL  → ve el inventario de TODAS las sedes (por defecto)
--    user_roles.sede = 'X'   → ve solo esa sede (más las de sedes_extra)
--  Para limitarlo a una sede después de crearlo:
--    update user_roles set sede = 'Pinares' where id = '<uuid del usuario>';
--
--  Correr UNA vez en Supabase → SQL Editor.
-- ════════════════════════════════════════════════════════════════════════

-- Inventario: solo lectura
drop policy if exists inventario_coordinador_select on inventario;
create policy inventario_coordinador_select on inventario
  for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role = 'coordinador'
          and (ur.sede is null or ur.sede = inventario.sede or inventario.sede = any(ur.sedes_extra))));

-- Envíos de mercadería: solo lectura (se muestran en la misma pantalla de inventario)
drop policy if exists envios_coordinador_select on envios_mercaderia;
create policy envios_coordinador_select on envios_mercaderia
  for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role = 'coordinador'
          and (ur.sede is null or ur.sede = envios_mercaderia.sede or envios_mercaderia.sede = any(ur.sedes_extra))));
