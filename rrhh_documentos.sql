-- ══════════════════════════════════════════════════════════════════════════
--  RRHH — documentos del empleado: incapacidades, citas médicas y
--  comprobantes de cita, adjuntados desde "Mi Portal".
--  Correr UNA vez en Supabase → SQL Editor, después de rrhh.sql.
--  Se puede repetir sin problema.
--
--  · El empleado sube el archivo (foto o PDF) a su propia carpeta del bucket
--    privado "rrhh-documentos" y registra el documento: queda "pendiente".
--  · Solo ve y borra (mientras esté pendiente) lo suyo.
--  · admin / admin_sedes ven todo, lo marcan revisado o rechazado, y desde
--    Planilla registran la incapacidad como novedad de la quincena.
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists rrhh_documentos (
  id               uuid primary key default gen_random_uuid(),
  empleado_id      uuid not null references empleados(id) on delete cascade,
  user_id          uuid,                         -- cuenta que lo subió (la pone la base)
  sede             text,                         -- sede de la ficha (la pone la base)
  tipo             text not null,                -- 'incapacidad' | 'cita_medica' | 'comprobante_cita' | 'otro'
  fecha_inicio     date not null,                -- incapacidad: desde · cita: fecha de la cita
  fecha_fin        date,                         -- incapacidad: hasta
  ente             text,                         -- incapacidad: 'ccss' | 'ins' | 'maternidad'
  numero           text,                         -- n.º de boleta / comprobante (opcional)
  nota             text,
  archivo_path     text not null,                -- ruta en el bucket rrhh-documentos
  archivo_nombre   text,
  archivo_tipo     text,
  estado           text not null default 'pendiente',   -- 'pendiente' | 'revisado' | 'rechazado'
  comentario_admin text,
  revisado_por     text,
  revisado_at      timestamptz,
  novedad_id       uuid,                         -- novedad de planilla creada a partir de esta incapacidad
  created_at       timestamptz default now()
);
create index if not exists rrhh_doc_emp_idx  on rrhh_documentos (empleado_id, created_at desc);
create index if not exists rrhh_doc_sede_idx on rrhh_documentos (sede, estado);

do $$ begin
  alter table rrhh_documentos add constraint rrhh_doc_tipo_chk
    check (tipo in ('incapacidad','cita_medica','comprobante_cita','otro'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table rrhh_documentos add constraint rrhh_doc_estado_chk
    check (estado in ('pendiente','revisado','rechazado'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table rrhh_documentos add constraint rrhh_doc_ente_chk
    check (ente is null or ente in ('ccss','ins','maternidad'));
exception when duplicate_object then null; end $$;

-- ── Guardia: lo que el empleado no puede decidir lo pone la base ────────────
create or replace function rrhh_documentos_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_admin boolean := exists (select 1 from user_roles where id = auth.uid() and role in ('admin','admin_sedes'));
begin
  if TG_OP = 'INSERT' then
    new.created_at := now();
    select sede into new.sede from empleados where id = new.empleado_id;
    if not v_admin then
      new.user_id := auth.uid();
      new.estado := 'pendiente';
      new.comentario_admin := null; new.revisado_por := null; new.revisado_at := null; new.novedad_id := null;
    end if;
    return new;
  end if;
  -- UPDATE (solo administradores, por RLS): sella quién y cuándo revisó
  if new.estado is distinct from old.estado then
    new.revisado_por := coalesce(auth.jwt() ->> 'email', new.revisado_por);
    new.revisado_at := case when new.estado = 'pendiente' then null else now() end;
  end if;
  new.empleado_id := old.empleado_id; new.user_id := old.user_id; new.created_at := old.created_at;
  return new;
end;
$$;
drop trigger if exists rrhh_documentos_guard_trg on rrhh_documentos;
create trigger rrhh_documentos_guard_trg
  before insert or update on rrhh_documentos
  for each row execute function rrhh_documentos_guard();

-- ── RLS de la tabla ─────────────────────────────────────────────────────────
alter table rrhh_documentos enable row level security;

drop policy if exists rrhh_doc_admin_all on rrhh_documentos;
create policy rrhh_doc_admin_all on rrhh_documentos
  for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes')))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes')));

-- El empleado ve lo suyo
drop policy if exists rrhh_doc_self_select on rrhh_documentos;
create policy rrhh_doc_self_select on rrhh_documentos
  for select to authenticated
  using (user_id = auth.uid());

-- …y lo registra solo sobre SU ficha activa, en SU carpeta del bucket
drop policy if exists rrhh_doc_self_insert on rrhh_documentos;
create policy rrhh_doc_self_insert on rrhh_documentos
  for insert to authenticated
  with check (
    exists (select 1 from empleados e where e.id = rrhh_documentos.empleado_id
              and e.user_id = auth.uid() and e.activo is distinct from false)
    and split_part(archivo_path, '/', 1) = auth.uid()::text
  );

-- …y puede borrarlo mientras siga pendiente (por si se equivocó de archivo)
drop policy if exists rrhh_doc_self_delete on rrhh_documentos;
create policy rrhh_doc_self_delete on rrhh_documentos
  for delete to authenticated
  using (user_id = auth.uid() and estado = 'pendiente');

-- ── Bucket privado para los archivos (10 MB, fotos y PDF) ───────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('rrhh-documentos', 'rrhh-documentos', false, 10485760,
        array['image/jpeg','image/png','image/webp','image/heic','image/heif','application/pdf'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- Cada cuenta sube, ve y borra solo en su carpeta (<user_id>/...); los administradores, todo.
drop policy if exists rrhh_docs_obj_insert on storage.objects;
create policy rrhh_docs_obj_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'rrhh-documentos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists rrhh_docs_obj_select on storage.objects;
create policy rrhh_docs_obj_select on storage.objects
  for select to authenticated
  using (bucket_id = 'rrhh-documentos' and (
    (storage.foldername(name))[1] = auth.uid()::text
    or exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes'))));

drop policy if exists rrhh_docs_obj_delete on storage.objects;
create policy rrhh_docs_obj_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'rrhh-documentos' and (
    (storage.foldername(name))[1] = auth.uid()::text
    or exists (select 1 from user_roles ur where ur.id = auth.uid() and ur.role in ('admin','admin_sedes'))));

-- Comprobación: la tabla y el bucket
select 'tabla' as que, count(*)::text as valor from information_schema.tables where table_name = 'rrhh_documentos'
union all
select 'bucket', coalesce(max(id), '(no existe)') from storage.buckets where id = 'rrhh-documentos';
