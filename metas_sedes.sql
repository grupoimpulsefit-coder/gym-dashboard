-- ══════════════════════════════════════════════════════════════════════════
--  METAS DE COBRO POR SEDE Y MES
--  Correr UNA vez en el SQL editor de Supabase. Se puede repetir sin problema.
--
--  Una fila por sede y mes ('YYYY-MM', el mismo mes_orden de gym_snapshots).
--  La usan comparativa.html y sedes.html para mostrar cuánto falta para la
--  meta. Quién la cambió y cuándo lo sella el servidor.
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists metas_sedes (
  sede        text not null,
  mes_orden   text not null check (mes_orden ~ '^\d{4}-\d{2}$'),
  monto       numeric(14,2) not null check (monto > 0),
  updated_by  text,
  updated_at  timestamptz not null default now(),
  primary key (sede, mes_orden)
);

alter table metas_sedes enable row level security;

-- Ver: los roles administrativos
drop policy if exists metas_select on metas_sedes;
create policy metas_select on metas_sedes
  for select to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
                 and ur.role in ('admin','admin_sedes','admin_g')));

-- Crear / cambiar / quitar: admin y admin_sedes
drop policy if exists metas_insert on metas_sedes;
create policy metas_insert on metas_sedes
  for insert to authenticated
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
                      and ur.role in ('admin','admin_sedes')));

drop policy if exists metas_update on metas_sedes;
create policy metas_update on metas_sedes
  for update to authenticated
  using      (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes')))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes')));

drop policy if exists metas_delete on metas_sedes;
create policy metas_delete on metas_sedes
  for delete to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
                 and ur.role in ('admin','admin_sedes')));

-- Sella quién y cuándo: el correo sale del token, no del navegador
create or replace function metas_sedes_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.updated_by := coalesce(auth.jwt() ->> 'email', new.updated_by);
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists metas_sedes_guard_trg on metas_sedes;
create trigger metas_sedes_guard_trg
  before insert or update on metas_sedes
  for each row execute function metas_sedes_guard();

-- Comprobación: deberían aparecer las 4 políticas
select policyname, cmd from pg_policies where tablename = 'metas_sedes' order by policyname;
