-- ════════════════════════════════════════════════════════════════════════
--  Sedes adicionales por usuario (multi-sede para recepción / admin_sucursal)
--  Un usuario tiene su sede principal (user_roles.sede) y, opcionalmente,
--  una lista de sedes EXTRA donde también puede operar (cubrir turnos, etc.).
--  Correr UNA vez en Supabase → SQL Editor.
-- ════════════════════════════════════════════════════════════════════════

-- 1) Columna con las sedes adicionales
alter table user_roles add column if not exists sedes_extra text[];

-- 2) Función para que un ADMIN asigne las sedes extra de un usuario.
--    user_roles no usa RLS y el cliente no puede hacer UPDATE directo, así que
--    se hace por RPC con SECURITY DEFINER validando que quien llama es admin.
create or replace function set_user_sedes(p_id uuid, p_extra text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_role text;
begin
  select role into v_role from user_roles where id = auth.uid();
  if v_role is null or v_role not in ('admin','admin_sedes','admin_g') then
    raise exception 'No autorizado';
  end if;
  update user_roles
     set sedes_extra = (
        select array_agg(distinct s)
          from unnest(coalesce(p_extra, '{}'::text[])) s
         where s is not null and s <> ''
     )
   where id = p_id;
end;
$$;

revoke all on function set_user_sedes(uuid, text[]) from public;
grant execute on function set_user_sedes(uuid, text[]) to authenticated;

-- 3) POLICIES actualizadas: recepción / admin_sucursal pueden operar en su
--    sede principal O en cualquiera de sus sedes_extra.
--    (Reemplazan las de caja.sql y gastos.sql; se pueden correr aquí directo.)

-- cierres_caja
drop policy if exists cierres_rw on cierres_caja;
create policy cierres_rw on cierres_caja
  for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
          and (ur.role in ('admin','admin_sedes','admin_g')
               or (ur.role in ('recepcion','admin_sucursal') and (ur.sede = cierres_caja.sede or cierres_caja.sede = any(ur.sedes_extra))))))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
          and (ur.role in ('admin','admin_sedes','admin_g')
               or (ur.role in ('recepcion','admin_sucursal') and (ur.sede = cierres_caja.sede or cierres_caja.sede = any(ur.sedes_extra))))));

-- inventario (recepción: leer y descontar en su sede o extras)
drop policy if exists inventario_recep_select on inventario;
create policy inventario_recep_select on inventario
  for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('recepcion','admin_sucursal')
          and (ur.sede = inventario.sede or inventario.sede = any(ur.sedes_extra))));
drop policy if exists inventario_recep_update on inventario;
create policy inventario_recep_update on inventario
  for update to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('recepcion','admin_sucursal')
          and (ur.sede = inventario.sede or inventario.sede = any(ur.sedes_extra))))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('recepcion','admin_sucursal')
          and (ur.sede = inventario.sede or inventario.sede = any(ur.sedes_extra))));

-- envios_mercaderia (recepción: ver y aceptar de su sede o extras)
drop policy if exists envios_recep_select on envios_mercaderia;
create policy envios_recep_select on envios_mercaderia
  for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('recepcion','admin_sucursal')
          and (ur.sede = envios_mercaderia.sede or envios_mercaderia.sede = any(ur.sedes_extra))));
drop policy if exists envios_recep_update on envios_mercaderia;
create policy envios_recep_update on envios_mercaderia
  for update to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('recepcion','admin_sucursal')
          and (ur.sede = envios_mercaderia.sede or envios_mercaderia.sede = any(ur.sedes_extra))))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('recepcion','admin_sucursal')
          and (ur.sede = envios_mercaderia.sede or envios_mercaderia.sede = any(ur.sedes_extra))));

-- sinpe_registrados
drop policy if exists sinpe_rw on sinpe_registrados;
create policy sinpe_rw on sinpe_registrados
  for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
          and (ur.role in ('admin','admin_sedes','admin_g')
               or (ur.role in ('recepcion','admin_sucursal') and (ur.sede = sinpe_registrados.sede or sinpe_registrados.sede = any(ur.sedes_extra))))))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
          and (ur.role in ('admin','admin_sedes','admin_g')
               or (ur.role in ('recepcion','admin_sucursal') and (ur.sede = sinpe_registrados.sede or sinpe_registrados.sede = any(ur.sedes_extra))))));

-- gastos (recepción: ver e insertar en su sede o extras)
drop policy if exists gastos_select on gastos;
create policy gastos_select on gastos
  for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
          and (ur.role in ('admin','admin_sedes','admin_g')
               or (ur.role in ('recepcion','admin_sucursal') and (ur.sede = gastos.sede or gastos.sede = any(ur.sedes_extra))))));
drop policy if exists gastos_insert on gastos;
create policy gastos_insert on gastos
  for insert to authenticated
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
          and (ur.role in ('admin','admin_sedes','admin_g')
               or (ur.role in ('recepcion','admin_sucursal') and (ur.sede = gastos.sede or gastos.sede = any(ur.sedes_extra))))));
