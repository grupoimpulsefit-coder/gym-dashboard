-- ══════════════════════════════════════════════════════════════════════════
--  PLANES DE NATACIÓN — ajustes manuales del conteo
--  Correr UNA vez en el SQL editor de Supabase. Se puede repetir sin problema.
--
--  nat.html cuenta "usuarios con plan de natación" por el nombre del plan
--  (natación, nat, aquafitness, aquaterapia, estimulación, ejecutivo…).
--  Esta tabla guarda las excepciones que se marcan desde el navegador:
--    incluir = true  → el plan cuenta aunque su nombre no calce
--    incluir = false → el plan NO cuenta aunque su nombre calce
--  plan_norm es el nombre en minúsculas, sin tildes ni espacios dobles.
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists planes_natacion (
  plan_norm   text primary key,
  plan        text not null,
  incluir     boolean not null,
  updated_by  text,
  updated_at  timestamptz not null default now()
);

alter table planes_natacion enable row level security;

-- Ver: cualquier usuario que entra a nat.html (el conteo lo necesita)
drop policy if exists planes_nat_select on planes_natacion;
create policy planes_nat_select on planes_natacion
  for select to authenticated using (true);

-- Cambiar: admin y admin_sedes
drop policy if exists planes_nat_insert on planes_natacion;
create policy planes_nat_insert on planes_natacion
  for insert to authenticated
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
                      and ur.role in ('admin','admin_sedes')));

drop policy if exists planes_nat_update on planes_natacion;
create policy planes_nat_update on planes_natacion
  for update to authenticated
  using      (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes')))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes')));

drop policy if exists planes_nat_delete on planes_natacion;
create policy planes_nat_delete on planes_natacion
  for delete to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
                 and ur.role in ('admin','admin_sedes')));

-- Sella quién y cuándo
create or replace function planes_natacion_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.updated_by := coalesce(auth.jwt() ->> 'email', new.updated_by);
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists planes_natacion_guard_trg on planes_natacion;
create trigger planes_natacion_guard_trg
  before insert or update on planes_natacion
  for each row execute function planes_natacion_guard();

-- Comprobación: deberían aparecer las 4 políticas
select policyname, cmd from pg_policies where tablename = 'planes_natacion' order by policyname;
