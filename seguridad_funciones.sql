-- ══════════════════════════════════════════════════════════════════════════
--  SEGURIDAD — quitar a los visitantes (anon) el permiso de ejecutar
--  funciones SECURITY DEFINER.
--  Correr en el SQL editor de Supabase. Se puede repetir sin problema.
--
--  Las funciones SECURITY DEFINER corren con permisos de su dueño y saltan la
--  seguridad por filas. Postgres da EXECUTE a PUBLIC por defecto y Supabase
--  además se lo da a anon directamente, así que quitarlo de uno solo no basta
--  (por eso aprobar_horas, mi_rol, etc. seguían abiertas): hay que quitarlo
--  de "anon, public" y volver a darlo a authenticated donde la app lo usa.
--  service_role conserva su permiso propio (no viene de PUBLIC).
--
--  Revisado en el código (*.html, *.js y supabase/functions):
--    · factura.html es la ÚNICA página que llama RPC sin sesión (usa la llave
--      pública como token). Llama tipos_clase_publicos, sede_por_receptor y
--      enviar_factura_instructor → esas tres siguen abiertas a anon a
--      propósito (ver pagos_instructores.sql).
--    · Todas las demás RPC se llaman con el token de quien inició sesión:
--      caja.html, movil.html, index.html, mediciones.html,
--      horas_instructores.js, pagos_instructores.js y la función asistente
--      (que llama como el usuario, no como servidor).
--    · mi_rol, ve_stock, es_de_caja y fin_es_dueno solo se usan en reglas
--      RLS para "authenticated" y dentro de otras funciones SECURITY DEFINER
--      (que corren como el dueño), así que anon no las necesita.
--    · Las funciones de trigger no necesitan EXECUTE de nadie: Postgres no
--      revisa ese permiso al disparar el trigger. Se cierran del todo.
--
--  OJO: si algún otro .sql hace DROP FUNCTION + CREATE (no "create or
--  replace"), los permisos vuelven al default; correr este archivo después.
-- ══════════════════════════════════════════════════════════════════════════

-- ── Funciones que usa la app con sesión: solo authenticated ─────────────────
revoke execute on function public.aceptar_envio(uuid, jsonb, text) from anon, public;
grant  execute on function public.aceptar_envio(uuid, jsonb, text) to authenticated;

revoke execute on function public.aclarar_sinpe(text, text, numeric, text, jsonb, text) from anon, public;
grant  execute on function public.aclarar_sinpe(text, text, numeric, text, jsonb, text) to authenticated;

revoke execute on function public.anular_factura_caja(uuid, text) from anon, public;
grant  execute on function public.anular_factura_caja(uuid, text) to authenticated;

revoke execute on function public.aprobar_horas(text, date) from anon, public;
grant  execute on function public.aprobar_horas(text, date) to authenticated;

revoke execute on function public.reabrir_horas(text, date) from anon, public;
grant  execute on function public.reabrir_horas(text, date) to authenticated;

revoke execute on function public.asistente_agregar_detalle(bigint, text) from anon, public;
grant  execute on function public.asistente_agregar_detalle(bigint, text) to authenticated;

revoke execute on function public.solicitar_anulacion_factura(uuid, text) from anon, public;
grant  execute on function public.solicitar_anulacion_factura(uuid, text) to authenticated;

revoke execute on function public.resolver_anulacion_factura(bigint, boolean, text) from anon, public;
grant  execute on function public.resolver_anulacion_factura(bigint, boolean, text) to authenticated;

revoke execute on function public.buscar_cliente_pin(text) from anon, public;
grant  execute on function public.buscar_cliente_pin(text) to authenticated;

revoke execute on function public.vender_evento_caja(uuid, uuid, text, text, text, text, text, numeric, text) from anon, public;
grant  execute on function public.vender_evento_caja(uuid, uuid, text, text, text, text, text, numeric, text) to authenticated;

revoke execute on function public.facturar_caja(uuid, text, jsonb, numeric, text) from anon, public;
grant  execute on function public.facturar_caja(uuid, text, jsonb, numeric, text) to authenticated;

revoke execute on function public.facturar_caja_v2(uuid, jsonb, jsonb, numeric) from anon, public;
grant  execute on function public.facturar_caja_v2(uuid, jsonb, jsonb, numeric) to authenticated;

revoke execute on function public.factura_ya_cargada(text, uuid) from anon, public;
grant  execute on function public.factura_ya_cargada(text, uuid) to authenticated;

revoke execute on function public.marcar_pago_instructor(uuid[], boolean) from anon, public;
grant  execute on function public.marcar_pago_instructor(uuid[], boolean) to authenticated;

revoke execute on function public.guardar_push(text, text, text, text) from anon, public;
grant  execute on function public.guardar_push(text, text, text, text) to authenticated;

revoke execute on function public.quitar_push(text) from anon, public;
grant  execute on function public.quitar_push(text) to authenticated;

revoke execute on function public.inventario_caja(text) from anon, public;
grant  execute on function public.inventario_caja(text) to authenticated;

revoke execute on function public.registrar_conteo(uuid, text, jsonb) from anon, public;
grant  execute on function public.registrar_conteo(uuid, text, jsonb) to authenticated;

revoke execute on function public.set_user_sedes(uuid, text[]) from anon, public;
grant  execute on function public.set_user_sedes(uuid, text[]) to authenticated;

revoke execute on function public.mediciones_instructores(text) from anon, public;
grant  execute on function public.mediciones_instructores(text) to authenticated;

-- ── Funciones auxiliares de reglas RLS: solo authenticated ──────────────────
revoke execute on function public.mi_rol() from anon, public;
grant  execute on function public.mi_rol() to authenticated;

revoke execute on function public.ve_stock(text) from anon, public;
grant  execute on function public.ve_stock(text) to authenticated;

revoke execute on function public.es_de_caja(text) from anon, public;
grant  execute on function public.es_de_caja(text) to authenticated;

revoke execute on function public.fin_es_dueno() from anon, public;
grant  execute on function public.fin_es_dueno() to authenticated;

-- Uso interno de otras funciones (no se llama por RPC desde ninguna página)
revoke execute on function public.sinpe_marcar_dias(uuid, text, numeric, jsonb, uuid) from anon, authenticated, public;

-- ── Funciones de trigger: nadie las llama por RPC ───────────────────────────
revoke execute on function public.catalogo_ventas_guard()     from anon, authenticated, public;
revoke execute on function public.cierres_apertura_ref()      from anon, authenticated, public;
revoke execute on function public.cierres_guard()             from anon, authenticated, public;
revoke execute on function public.horarios_touch()            from anon, authenticated, public;
revoke execute on function public.inventario_guard()          from anon, authenticated, public;
revoke execute on function public.inventario_mov_baja()       from anon, authenticated, public;
revoke execute on function public.inventario_mov_log()        from anon, authenticated, public;
revoke execute on function public.marcas_horario_guard()      from anon, authenticated, public;
revoke execute on function public.mediciones_bloqueos_guard() from anon, authenticated, public;
revoke execute on function public.mediciones_guard()          from anon, authenticated, public;
revoke execute on function public.mediciones_slot_libre()     from anon, authenticated, public;
revoke execute on function public.metas_sedes_guard()         from anon, authenticated, public;
revoke execute on function public.planes_natacion_guard()     from anon, authenticated, public;
revoke execute on function public.rrhh_documentos_guard()     from anon, authenticated, public;

-- ── Públicas a propósito (factura.html, sin sesión) ─────────────────────────
-- Se re-afirman para que quede claro que NO es un olvido.
grant execute on function public.tipos_clase_publicos() to anon, authenticated;
grant execute on function public.sede_por_receptor(text) to anon, authenticated;
grant execute on function public.enviar_factura_instructor(text, text, jsonb, text, text, text, text, text) to anon, authenticated;
