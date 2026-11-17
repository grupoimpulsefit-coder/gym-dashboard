-- ══════════════════════════════════════════════════════════════════════════
--  Gastos: detalle editable de la factura + titular de la cuenta del instructor
--  Es idempotente: se puede correr varias veces sin error.
-- ══════════════════════════════════════════════════════════════════════════

-- Detalle de la factura (texto libre, editable). Si queda vacío, la app
-- muestra el resumen de clases que viene del XML / recibo / horas.
alter table gastos add column if not exists detalle text;

-- Nombre de la persona a cuyo nombre está la cuenta / SINPE del instructor
-- (si es otra persona). Vacío = la cuenta está a nombre del instructor.
alter table instructores add column if not exists titular_cuenta text;

notify pgrst, 'reload schema';
