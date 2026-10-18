-- ══════════════════════════════════════════════════════════════════════════
--  AUDITORÍA SINPE — decisiones manuales de conciliacion.html
--  Correr una vez en el SQL editor de Supabase. Se puede repetir sin problema.
--
--  El cruce automático (referencia, cédula, nombre, monto) se recalcula cada
--  vez que se cargan los archivos. Aquí solo se guarda lo que una persona
--  confirma a mano, para que no haya que repetirlo:
--    • vinculado   → un SINPE paga estas facturas (clave = 'ref:<referencia>')
--    • sin_factura → un SINPE que no corresponde a ninguna factura (pago
--                    adelantado, otra sede, devolución…), con nota
--    • sin_sinpe   → una factura marcada SINPE que se pagó por otro medio o
--                    se registró mal (clave = 'fac:<origen>:<número>'), con nota
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists sinpe_conciliacion (
  id          uuid primary key default gen_random_uuid(),
  sede        text not null,
  clave       text not null,                 -- 'ref:<ReferenciaSinpe>' o 'fac:<origen>:<numero>'
  estado      text not null check (estado in ('vinculado','sin_factura','sin_sinpe')),
  referencia  text,                          -- ReferenciaSinpe (vinculado / sin_factura)
  facturas    jsonb not null default '[]',   -- [ { clave, numero, cliente, monto, fecha } ]
  nota        text,
  creado_por  text default (auth.jwt() ->> 'email'),
  created_at  timestamptz default now()
);
create unique index if not exists sinpe_conciliacion_clave_idx on sinpe_conciliacion (sede, clave);

alter table sinpe_conciliacion enable row level security;
drop policy if exists sinpe_conciliacion_rw on sinpe_conciliacion;
create policy sinpe_conciliacion_rw on sinpe_conciliacion
  for all to authenticated
  using (exists (select 1 from user_roles ur where ur.id = auth.uid()
          and (ur.role in ('admin','admin_sedes','admin_g')
               or (ur.role = 'coordinador' and (ur.sede = sinpe_conciliacion.sede or sinpe_conciliacion.sede = any(ur.sedes_extra))))))
  with check (exists (select 1 from user_roles ur where ur.id = auth.uid()
          and (ur.role in ('admin','admin_sedes','admin_g')
               or (ur.role = 'coordinador' and (ur.sede = sinpe_conciliacion.sede or sinpe_conciliacion.sede = any(ur.sedes_extra))))));
