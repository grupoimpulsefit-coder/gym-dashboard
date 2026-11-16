-- ══════════════════════════════════════════════════════════════════════════
--  SEGURIDAD — arreglos de la auditoría (noviembre 2026)
--  Correr UNA vez en el SQL editor de Supabase. Se puede repetir sin problema.
-- ══════════════════════════════════════════════════════════════════════════

-- ── 1) Fotos del datáfono (bucket cierres-caja) ─────────────────────────────
-- Antes: una sola regla ALL sin sede → recepción podía ver, reemplazar o BORRAR
-- la foto de cualquier cierre de cualquier sede. Ahora:
--   · ver y subir: Administración en todas; caja solo en sus sedes (la carpeta
--     es la sede sin tildes y con _ , como la arma caja.html: 3_Rios, Natacion…)
--   · reemplazar: solo quien la subió y en los primeros 15 minutos
--     (caja.html sube con x-upsert; pasado ese rato la foto queda fija)
--   · borrar: solo admin / admin_sedes
create or replace function public.puede_foto_caja(p_carpeta text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from user_roles ur where ur.id = auth.uid() and (
    ur.role in ('admin','admin_sedes','admin_g')
    or (ur.role = 'coordinador' and ur.sede is null)
    or (ur.role in ('recepcion','admin_sucursal','coordinador') and p_carpeta in (
          select replace(translate(s, 'áéíóúÁÉÍÓÚ', 'aeiouAEIOU'), ' ', '_')
            from unnest(array[ur.sede] || coalesce(ur.sedes_extra, '{}')) s where s is not null))))
$$;
revoke all on function public.puede_foto_caja(text) from public;
grant execute on function public.puede_foto_caja(text) to authenticated;

drop policy if exists cierres_fotos_rw     on storage.objects;
drop policy if exists cierres_fotos_select on storage.objects;
drop policy if exists cierres_fotos_insert on storage.objects;
drop policy if exists cierres_fotos_update on storage.objects;
drop policy if exists cierres_fotos_delete on storage.objects;

create policy cierres_fotos_select on storage.objects
  for select to authenticated
  using (bucket_id = 'cierres-caja' and public.puede_foto_caja((storage.foldername(name))[1]));

create policy cierres_fotos_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'cierres-caja' and public.puede_foto_caja((storage.foldername(name))[1]));

create policy cierres_fotos_update on storage.objects
  for update to authenticated
  using (bucket_id = 'cierres-caja' and owner_id = auth.uid()::text and created_at > now() - interval '15 minutes')
  with check (bucket_id = 'cierres-caja' and owner_id = auth.uid()::text and public.puede_foto_caja((storage.foldername(name))[1]));

create policy cierres_fotos_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'cierres-caja' and public.mi_rol() in ('admin','admin_sedes'));

-- ── 2) promo_clientes: nombre, teléfono y PIN de clientes ───────────────────
-- Antes lo leía cualquier cuenta (también instructor y empleado). Ahora, los
-- mismos roles que leen gym_snapshots (ver seguridad_rls.sql).
drop policy if exists promo_clientes_select on promo_clientes;
create policy promo_clientes_select on promo_clientes
  for select to authenticated
  using (public.mi_rol() in ('admin','admin_sedes','admin_g','colaborador','recepcion','admin_sucursal','coordinador'));

-- ── 3) Tope de mensajes del asistente (Edge Function asistente) ─────────────
-- Una fila por mensaje; la función borra las de más de una hora. Solo la usa la
-- función (service role): RLS activo y sin reglas = nadie más la toca.
create table if not exists public.asistente_uso (
  user_id uuid not null references auth.users(id) on delete cascade,
  at      timestamptz not null default now()
);
create index if not exists asistente_uso_user_at on public.asistente_uso (user_id, at);
alter table public.asistente_uso enable row level security;
revoke all on public.asistente_uso from anon, authenticated;

-- ── 4) search_path fijo en funciones (aviso del linter de Supabase) ─────────
alter function public._den_dif(jsonb, jsonb)                          set search_path = public;
alter function public._den_total(jsonb)                               set search_path = public;
alter function public._fe_texto(xml, text)                            set search_path = public;
alter function public.dia_pago_instructor(timestamp with time zone)   set search_path = public;
alter function public.gastos_marca_pendiente()                        set search_path = public;
alter function public.gastos_xml_dia_pago()                           set search_path = public;
alter function public.horas_semana_guard()                            set search_path = public;
alter function public.norm_prod(text)                                 set search_path = public;
alter function public.plantillas_pago_guard()                         set search_path = public;

-- ── 5) Empleados creados sin sede ───────────────────────────────────────────
-- crear-usuario pedía la sede del rol empleado pero guardaba null. Se toma la
-- sede de su ficha en RRHH.
update user_roles ur set sede = e.sede
  from empleados e
 where e.user_id = ur.id and ur.role = 'empleado' and ur.sede is null and e.sede is not null;
