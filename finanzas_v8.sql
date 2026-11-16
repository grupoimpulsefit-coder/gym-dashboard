-- ══════════════════════════════════════════════════════════════════════════
--  FINANZAS v8 — precios del inventario y consumo estimado.
--  Correr DESPUÉS de finanzas_v7.sql. Se puede repetir sin problema.
--
--  · precio = lo que cuesta el paquete (ej. ₡4 600); por_paquete = cuántas
--    unidades trae (ej. 12 rollos). Costo por unidad = precio / por_paquete.
--  · La cantidad del inventario se lleva en unidades (rollos).
--  · fin_inv_consumo(): cuánto se ha sacado de cada producto (últimos 90 días)
--    y cuántos días de historial hay, para estimar el consumo por mes.
--    Es solo una estimación: no registra gastos.
-- ══════════════════════════════════════════════════════════════════════════

alter table fin_inventario add column if not exists precio numeric(12,2) check (precio >= 0);
alter table fin_inventario add column if not exists por_paquete numeric(12,2) not null default 1 check (por_paquete > 0);

-- Corre con los permisos de quien llama: solo ve productos de su grupo
create or replace function public.fin_inv_consumo()
returns table (item_id uuid, salidas numeric, dias numeric)
language sql stable set search_path = public
as $$
  select i.id,
         coalesce(sum(-m.cambio) filter (where m.cambio < 0 and m.created_at > now() - interval '90 days'), 0),
         -- días desde el primer movimiento (o desde que se creó), máximo 90
         least(90, greatest(0, extract(epoch from now() - least(i.created_at, min(m.created_at))) / 86400))::numeric(8,2)
    from fin_inventario i
    left join fin_inv_movs m on m.item_id = i.id
   group by i.id, i.created_at
$$;
revoke all on function public.fin_inv_consumo() from public, anon;
grant execute on function public.fin_inv_consumo() to authenticated;
