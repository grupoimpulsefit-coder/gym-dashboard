-- ════════════════════════════════════════════════════════════════════════
--  Rol COORDINADOR = mismos permisos que RECEPCIÓN + consulta de inventario
--
--  Antes el coordinador solo podía consultar el inventario. Esto le da además
--  Caja, Gastos y Mediciones de su sede, igual que recepción.
--  (La pantalla de inventario le sigue saliendo en solo lectura.)
--
--  Requisito: el coordinador debe tener SEDE asignada en user_roles, como
--  recepción. Para dársela:
--    update user_roles set sede = '3 Ríos' where id = '<uuid del usuario>';
--
--  Correr UNA vez en Supabase → SQL Editor.
-- ════════════════════════════════════════════════════════════════════════


-- ── Políticas de caja ──
create policy cierres_rw on cierres_caja
  for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
          and (ur.role in ('admin','admin_sedes','admin_g') or (ur.role in ('recepcion','admin_sucursal','coordinador') and (ur.sede = cierres_caja.sede or cierres_caja.sede = any(ur.sedes_extra))))))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
          and (ur.role in ('admin','admin_sedes','admin_g') or (ur.role in ('recepcion','admin_sucursal','coordinador') and (ur.sede = cierres_caja.sede or cierres_caja.sede = any(ur.sedes_extra))))));

create policy inventario_recep_select on inventario
  for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('recepcion','admin_sucursal','coordinador') and (ur.sede = inventario.sede or inventario.sede = any(ur.sedes_extra))));

create policy inventario_recep_update on inventario
  for update to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('recepcion','admin_sucursal','coordinador') and (ur.sede = inventario.sede or inventario.sede = any(ur.sedes_extra))))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('recepcion','admin_sucursal','coordinador') and (ur.sede = inventario.sede or inventario.sede = any(ur.sedes_extra))));

create policy envios_recep_select on envios_mercaderia
  for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('recepcion','admin_sucursal','coordinador') and (ur.sede = envios_mercaderia.sede or envios_mercaderia.sede = any(ur.sedes_extra))));

create policy envios_recep_update on envios_mercaderia
  for update to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('recepcion','admin_sucursal','coordinador') and (ur.sede = envios_mercaderia.sede or envios_mercaderia.sede = any(ur.sedes_extra))))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('recepcion','admin_sucursal','coordinador') and (ur.sede = envios_mercaderia.sede or envios_mercaderia.sede = any(ur.sedes_extra))));

create policy sinpe_rw on sinpe_registrados
  for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
          and (ur.role in ('admin','admin_sedes','admin_g') or (ur.role in ('recepcion','admin_sucursal','coordinador') and (ur.sede = sinpe_registrados.sede or sinpe_registrados.sede = any(ur.sedes_extra))))))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
          and (ur.role in ('admin','admin_sedes','admin_g') or (ur.role in ('recepcion','admin_sucursal','coordinador') and (ur.sede = sinpe_registrados.sede or sinpe_registrados.sede = any(ur.sedes_extra))))));

create policy cierres_fotos_rw on storage.objects
  for all to authenticated
  using (bucket_id = 'cierres-caja' and exists (select 1 from user_roles ur where ur.id = auth.uid()
          and ur.role in ('recepcion','admin_sucursal','coordinador','admin_sedes','admin_g','admin')))
  with check (bucket_id = 'cierres-caja' and exists (select 1 from user_roles ur where ur.id = auth.uid()
          and ur.role in ('recepcion','admin_sucursal','coordinador','admin_sedes','admin_g','admin')));

-- ── Políticas de gastos ──
create policy gastos_select on gastos
  for select to authenticated
  using (
    exists (select 1 from user_roles ur where ur.id = auth.uid()
            and (ur.role in ('admin','admin_sedes','admin_g')
                 or (ur.role in ('recepcion','admin_sucursal','coordinador') and (ur.sede = gastos.sede or gastos.sede = any(ur.sedes_extra)))))
  );

create policy gastos_insert on gastos
  for insert to authenticated
  with check (
    exists (select 1 from user_roles ur where ur.id = auth.uid()
            and (ur.role in ('admin','admin_sedes','admin_g')
                 or (ur.role in ('recepcion','admin_sucursal','coordinador') and (ur.sede = gastos.sede or gastos.sede = any(ur.sedes_extra)))))
  );

-- ── Políticas de mediciones ──
create policy mediciones_select on mediciones
  for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador','instructor')
             and (ur.sede = mediciones.sede or mediciones.sede = any(ur.sedes_extra))))));

create policy mediciones_insert on mediciones
  for insert to authenticated
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador')
             and (ur.sede = mediciones.sede or mediciones.sede = any(ur.sedes_extra))))));

create policy mediciones_update on mediciones
  for update to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador','instructor')
             and (ur.sede = mediciones.sede or mediciones.sede = any(ur.sedes_extra))))))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador','instructor')
             and (ur.sede = mediciones.sede or mediciones.sede = any(ur.sedes_extra))))));

create policy mediciones_delete on mediciones
  for delete to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and (ur.role in ('admin','admin_sedes','admin_g')
         or (ur.role in ('recepcion','admin_sucursal','coordinador')
             and (ur.sede = mediciones.sede or mediciones.sede = any(ur.sedes_extra))))));
