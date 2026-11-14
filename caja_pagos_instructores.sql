-- ══════════════════════════════════════════════════════════════════════════
--  CAJA ↔ PAGOS A INSTRUCTORES DE CAJA
--  Correr en Supabase → SQL Editor, después de recibos_plantillas.sql.
--  Se puede repetir sin problema.
--
--  · Las facturas, recibos y horas que se pagan de caja ya están en Gastos.
--    Cuando recepción anota la salida en el cierre de caja y elige ese pago,
--    la caja NO crea otro gasto: lo marca pagado con esta función.
--  · Recepción, coordinador y admin de sucursal solo en su sede (o sedes extra);
--    solo pagos de caja que no estén ya pagados.
-- ══════════════════════════════════════════════════════════════════════════

create or replace function marcar_pago_caja(p_ids uuid[])
returns integer language plpgsql security definer set search_path = public as $$
declare
  r record;
  n integer;
  quien text := coalesce(auth.jwt() ->> 'email', auth.uid()::text);
begin
  select role, sede, sedes_extra into r from user_roles where id = auth.uid();
  if r.role is null or r.role not in ('admin','admin_sedes','admin_g','recepcion','coordinador','admin_sucursal') then
    raise exception 'Su cuenta no puede marcar pagos de caja.';
  end if;
  update gastos g
     set pagado_at = now(), pagado_por = quien
   where g.id = any(p_ids)
     and g.origen in ('xml', 'recibo', 'horas')
     and g.pago_tipo = 'caja'
     and g.pagado_at is null
     and (r.role in ('admin','admin_sedes','admin_g')
          or g.sede = r.sede or g.sede = any(coalesce(r.sedes_extra, '{}')));
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function marcar_pago_caja(uuid[]) from anon, public;
grant execute on function marcar_pago_caja(uuid[]) to authenticated;

-- Comprobación
select proname from pg_proc where proname = 'marcar_pago_caja';
