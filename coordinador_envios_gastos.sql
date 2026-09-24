-- ══════════════════════════════════════════════════════════════════════════
--  COORDINADOR — dos permisos nuevos
--  Correr UNA vez en el SQL editor de Supabase. Se puede repetir sin problema.
--
--  1) Puede CREAR envíos de mercadería para SU sede (no para otras).
--     Un envío nunca baja el stock: solo suma cuando recepción lo acepta en
--     Caja indicando lo que realmente llegó. Por eso el coordinador solo
--     puede aumentar, nunca disminuir.
--     Quién lo envió queda sellado por el servidor (no se puede falsear).
--
--  2) Puede EDITAR gastos ya registrados de su sede (no borrarlos).
-- ══════════════════════════════════════════════════════════════════════════

-- ── 1) Envíos de mercadería ───────────────────────────────────────────────

-- El coordinador crea envíos solo para su sede (o sus sedes_extra)
drop policy if exists envios_coordinador_insert on envios_mercaderia;
create policy envios_coordinador_insert on envios_mercaderia
  for insert to authenticated
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
    and ur.role = 'coordinador'
    and (ur.sede = envios_mercaderia.sede or envios_mercaderia.sede = any(ur.sedes_extra))));

-- Sella quién creó el envío: el correo sale del token, no del cliente.
create or replace function envios_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.created_by := coalesce(auth.jwt() ->> 'email', new.created_by);
  new.created_at := now();
  new.estado     := coalesce(nullif(new.estado, ''), 'pendiente');
  return new;
end;
$$;
drop trigger if exists envios_guard_trg on envios_mercaderia;
create trigger envios_guard_trg
  before insert on envios_mercaderia
  for each row execute function envios_guard();

-- ── 2) Edición de gastos ──────────────────────────────────────────────────

-- Admin/admin_sedes/admin_g: cualquier gasto.
-- Coordinador: solo los de SU sede. Borrar sigue siendo exclusivo de admin.
drop policy if exists gastos_update on gastos;
create policy gastos_update on gastos
  for update to authenticated
  using (
    exists (select 1 from user_roles ur where ur.id = auth.uid()
            and (ur.role in ('admin','admin_sedes','admin_g')
                 or (ur.role = 'coordinador'
                     and (ur.sede = gastos.sede or gastos.sede = any(ur.sedes_extra)))))
  )
  with check (
    exists (select 1 from user_roles ur where ur.id = auth.uid()
            and (ur.role in ('admin','admin_sedes','admin_g')
                 or (ur.role = 'coordinador'
                     and (ur.sede = gastos.sede or gastos.sede = any(ur.sedes_extra)))))
  );

-- Comprobación: deberían aparecer las políticas nuevas
select tablename, policyname, cmd
from pg_policies
where policyname in ('envios_coordinador_insert','gastos_update')
order by tablename, policyname;
