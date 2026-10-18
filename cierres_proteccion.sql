-- ══════════════════════════════════════════════════════════════════════════
--  PROTECCIÓN DE LOS CIERRES DE CAJA
--  Correr UNA vez en el SQL editor de Supabase, DESPUÉS de seguridad_rls.sql
--  (usa mi_rol()) e inventario_ciego.sql (usa ve_stock()). Se puede repetir.
--
--  Antes, recepción / admin_sucursal / coordinador podían cambiar o borrar
--  un cierre ya cerrado (parcial o final) mandando el cambio directo a la base,
--  por ejemplo para tapar un faltante. La página nunca lo hace: solo edita el
--  turno ABIERTO. Ahora, para esos roles:
--    · Borrar un cierre: nunca.
--    · Turno abierto: igual que antes (se edita y se cierra normal).
--    · Turno ya cerrado: solo se puede tocar
--        - foto_analisis (verificar el datáfono): admin de sucursal, como en movil.
--        - el conteo de inventario: quien ve el stock real (ve_stock), como en
--          registrar_conteo().
--  Administradores (admin, admin_sedes, admin_g) y los procesos del servidor
--  (sin sesión) no tienen restricción.
-- ══════════════════════════════════════════════════════════════════════════

create or replace function cierres_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_rol  text := public.mi_rol();
  v_libres text[] := array['foto_analisis','inventario_apertura','inventario_cierre','updated_at'];
  n jsonb;
  o jsonb;
begin
  if auth.uid() is null or v_rol in ('admin','admin_sedes','admin_g') then
    return coalesce(new, old);
  end if;

  if tg_op = 'DELETE' then
    raise exception 'Solo un administrador puede borrar un cierre de caja.' using errcode = '42501';
  end if;

  if coalesce(old.estado, 'final') = 'abierto' then
    return new;
  end if;

  -- Turno cerrado: fuera de las columnas permitidas, nada puede cambiar
  -- (se compara como jsonb para no depender del tipo de cada columna)
  n := to_jsonb(new); o := to_jsonb(old);
  if (n - v_libres) is distinct from (o - v_libres) then
    raise exception 'El turno ya está cerrado: solo un administrador puede cambiarlo.' using errcode = '42501';
  end if;
  if n->'foto_analisis' is distinct from o->'foto_analisis' and v_rol <> 'admin_sucursal' then
    raise exception 'Solo el admin de sucursal o un administrador verifica el datáfono.' using errcode = '42501';
  end if;
  if (n->'inventario_apertura' is distinct from o->'inventario_apertura'
      or n->'inventario_cierre' is distinct from o->'inventario_cierre')
     and not public.ve_stock(old.sede) then
    raise exception 'El turno ya está cerrado: el conteo no se puede cambiar.' using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists cierres_guard on cierres_caja;
create trigger cierres_guard
  before update or delete on cierres_caja
  for each row execute function cierres_guard();
