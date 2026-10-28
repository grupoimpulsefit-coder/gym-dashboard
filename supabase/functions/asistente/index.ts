// ════════════════════════════════════════════════════════════════════════
//  Edge Function: asistente
//  Chat de ayuda dentro de la app: responde dudas del personal con el Manual
//  Operativo (manual.ts) y lo que se sabe de cómo funciona jykc.dev. Si la
//  respuesta no está, o el trámite necesita a Administración (anular una
//  venta, revisar un SINPE, un descuadre…), crea un ticket en
//  asistente_tickets (ver asistente.sql) para que Administración lo atienda.
//
//  Requiere el secreto ANTHROPIC_API_KEY (el mismo de analizar-datafono).
//  Se publica con el nombre exacto: asistente  (incluye manual.ts)
//    supabase functions deploy asistente
//  (SUPABASE_URL, SUPABASE_ANON_KEY y SUPABASE_SERVICE_ROLE_KEY ya vienen inyectadas.)
// ════════════════════════════════════════════════════════════════════════
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Anthropic from 'npm:@anthropic-ai/sdk';
import { MANUAL } from './manual.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const MODEL = 'claude-opus-5-5';
const MAX_MENSAJES = 40;          // historial que se acepta del navegador (unos 10 intercambios)
const MAX_HISTORIAL_BYTES = 300_000;
const TIPOS = ['duda', 'anular_venta', 'revisar_sinpe', 'descuadre_caja', 'error_app', 'otro'] as const;

const MAPA_APP = `Módulos de jykc.dev (cada uno es una pantalla; se entra desde el menú principal):
• /caja — Cierre de Caja. Pestañas Cierre y Facturación. Abrir turno (denominaciones + inventario inicial), facturar productos/minita/eventos, cargar Informe de Ventas de WStudio, Reporte SINPE de Ridivi, foto del datáfono, conteo de inventario, opción de minita, recuadro verde «Para WStudio», cierre parcial y cierre final (definitivo; descargar el PDF antes).
• /gastos — Registrar gastos (necesitan factura y aprobación de Administración) y pagos de clases grupales / instructores de planta.
• /mediciones — Agenda semanal de mediciones en bloques de 15 minutos. Recepción agenda; el instructor marca la rutina completa o incompleta.
• /inventario — Consulta de stock, precios y faltantes por sede (recepción solo lectura).
• /conciliacion — Auditoría SINPE: qué facturas tienen su SINPE y cuáles no.
• /rrhh — Mi Portal (para quien está en planilla): saldo y solicitud de vacaciones, día libre sin goce, incapacidades, citas médicas y comprobantes. Administración ve ahí Recursos Humanos.
• /planilla, /sedes, /comparativa, /otros, /nat — módulos de Administración (planilla quincenal, reportes por sede, rentabilidad de productos, academia de natación).
Sedes: 3 Ríos, Pinares, Sabanilla (gimnasio) y Natación (academia).
Roles: recepcion, admin_sucursal, instructor, coordinador, colaborador y Administración (admin, admin_sedes, admin_g).
Sistemas externos: WStudio (membresías y su caja), Ridivi (SINPE Móvil). La sesión se cierra sola tras un rato sin actividad; si una pantalla falla con "sesión vencida", volver a iniciar sesión.`;

const INSTRUCCIONES = `Sos el asistente de ayuda de jykc.dev, el sistema de gestión de Fit and Train Fitness Club (Costa Rica). Te escribe el personal del club (recepcionistas, instructores, coordinadores) desde dentro de la app.

Cómo responder:
• Respondé solo con lo que dicen el Manual Operativo y el mapa de la app de abajo, más las respuestas de Administración que se te den. No inventes pasos, montos, botones, plazos ni políticas.
• Tratá a la persona de usted, en español sencillo y corto. Para procedimientos, dá los pasos numerados tal como están en el manual y mencioná la sección (p. ej. "Manual 5, Paso 7").
• Si hay actualizaciones con fecha (sección "Actualización de procedimientos"), lo vigente es lo más reciente.
• Si la persona es de la sede Natación, aplicá también las diferencias para Natación.

Cuándo crear un ticket (herramienta crear_ticket):
• Si la respuesta NO está en el manual ni en las respuestas de Administración: creá un ticket tipo "duda" con la pregunta, y decile que Administración la va a responder y que la verá en la pestaña "Mis consultas" de este chat. No adivines.
• Si pide algo que solo Administración puede hacer o autorizar (anular o corregir una venta o un cierre, revisar un SINPE que no aparece o no cuadra, un descuadre de caja, reembolsos, descuentos fuera de tarifa, excepciones al reglamento, un error de la app): creá el ticket con el tipo que corresponda. Nunca digas que la acción ya se hizo: decí que quedó solicitada.
• Antes de crear un ticket de trámite, pedí los datos que falten si son necesarios para que Administración actúe (fecha, sede, monto, número de factura o los últimos 6 dígitos de la referencia SINPE, nombre del cliente). Si ya los tiene, no los vuelvas a pedir.
• Un ticket por asunto. Si es una simple duda que sí está en el manual, respondé sin ticket.
• Emergencias médicas o accidentes: indicá de inmediato el procedimiento del manual (sección 11) y que avise a Administración; no esperes a un ticket.
• No compartas datos personales de colaboradores, clientes ni dueños.`;

const TOOLS: Anthropic.Beta.BetaTool[] = [{
  name: 'crear_ticket',
  description: 'Crea un ticket para Administración: una duda que no está en el manual, o un trámite que solo Administración puede hacer o autorizar. Devuelve el número de ticket.',
  strict: true,
  input_schema: {
    type: 'object',
    additionalProperties: false,
    required: ['tipo', 'resumen', 'detalle'],
    properties: {
      tipo: { type: 'string', enum: [...TIPOS], description: 'duda = pregunta sin respuesta en el manual; anular_venta; revisar_sinpe; descuadre_caja; error_app = algo de la app no funciona; otro.' },
      resumen: { type: 'string', description: 'Una línea, lo que hay que resolver.' },
      detalle: { type: 'string', description: 'Datos útiles para Administración: fecha, sede, monto, factura, referencia SINPE, cliente, qué intentó. Vacío si no hay.' },
    },
  },
}];

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Método no permitido' }, 405);

  try {
    const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
    const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
    const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY');
    if (!ANTHROPIC_API_KEY) return json({ error: 'Falta configurar ANTHROPIC_API_KEY en los secretos de la función.' }, 500);

    // 1) Quién pregunta: cualquier cuenta con rol en user_roles ---------------
    const token = (req.headers.get('Authorization') || '').replace('Bearer ', '').trim();
    if (!token) return json({ error: 'No autenticado' }, 401);
    const asCaller = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: `Bearer ${token}` } } });
    const { data: caller } = await asCaller.auth.getUser();
    if (!caller?.user) return json({ error: 'Sesión inválida' }, 401);
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE);
    const { data: yo } = await admin.from('user_roles').select('role, nombre, sede').eq('id', caller.user.id).single();
    if (!yo?.role) return json({ error: 'Sin permiso' }, 403);

    // 2) Mensaje nuevo + historial que guarda el navegador ---------------------
    const body = await req.json().catch(() => ({}));
    const mensaje = String(body.mensaje || '').trim().slice(0, 4000);
    if (!mensaje) return json({ error: 'Mensaje vacío.' }, 400);
    const historial: Anthropic.Beta.BetaMessageParam[] = Array.isArray(body.historial) ? body.historial : [];
    if (historial.length > MAX_MENSAJES || JSON.stringify(historial).length > MAX_HISTORIAL_BYTES)
      return json({ error: 'La conversación es muy larga. Toque "Nueva" para empezar otra.', reiniciar: true }, 400);
    if (historial.some(m => m?.role !== 'user' && m?.role !== 'assistant'))
      return json({ error: 'Historial inválido.', reiniciar: true }, 400);
    const pagina = String(body.pagina || '').slice(0, 60);

    // 3) Respuestas de Administración que se le enseñaron al asistente ---------
    const { data: aprendidas } = await admin.from('asistente_tickets')
      .select('resumen, respuesta').eq('en_asistente', true).not('respuesta', 'is', null)
      .order('resuelto_at', { ascending: false }).limit(200);
    const extra = (aprendidas || []).map(t => `P: ${t.resumen}\nR: ${t.respuesta}`).join('\n\n');

    // El bloque grande (instrucciones + mapa + manual) va primero y en caché; lo que
    // cambia (respuestas aprendidas, quién pregunta) va después del punto de caché.
    const system: Anthropic.Beta.BetaTextBlockParam[] = [
      { type: 'text', text: `${INSTRUCCIONES}\n\n═══ MAPA DE LA APP ═══\n${MAPA_APP}\n\n═══ MANUAL OPERATIVO ═══\n${MANUAL}`, cache_control: { type: 'ephemeral' } },
      { type: 'text', text: `═══ RESPUESTAS DE ADMINISTRACIÓN (valen igual que el manual; si chocan, mandan estas) ═══\n${extra || '(ninguna todavía)'}\n\n═══ QUIÉN PREGUNTA ═══\nNombre: ${yo.nombre || caller.user.email}\nRol: ${yo.role}\nSede: ${yo.sede || 'sin sede fija'}\nPantalla abierta: ${pagina || 'menú principal'}` },
    ];

    const messages: Anthropic.Beta.BetaMessageParam[] = [...historial, { role: 'user', content: mensaje }];
    const client = new Anthropic({ apiKey: ANTHROPIC_API_KEY });
    const tickets: number[] = [];

    // 4) Bucle de herramientas (a lo sumo unas pocas vueltas) -------------------
    let msg: Anthropic.Beta.BetaMessage | null = null;
    for (let vuelta = 0; vuelta < 4; vuelta++) {
      try {
        msg = await client.beta.messages.create({
          model: MODEL,
          max_tokens: 8000,
          output_config: { effort: 'low' },
          betas: ['server-side-fallback-2026-07-01'],
          fallbacks: 'default',
          system, tools: TOOLS, messages,
        });
      } catch (e) {
        if (e instanceof Anthropic.APIError) return json({ error: `El asistente no está disponible (${e.status ?? 'sin conexión'}). Intente de nuevo en un momento.` }, 502);
        throw e;
      }
      messages.push({ role: 'assistant', content: msg.content });
      if (msg.stop_reason !== 'tool_use') break;

      const resultados: Anthropic.Beta.BetaToolResultBlockParam[] = [];
      for (const b of msg.content) {
        if (b.type !== 'tool_use') continue;
        const inp = b.input as { tipo?: string; resumen?: string; detalle?: string };
        const tipo = (TIPOS as readonly string[]).includes(String(inp.tipo)) ? String(inp.tipo) : 'otro';
        const { data: t, error } = await admin.from('asistente_tickets').insert({
          user_id: caller.user.id, usuario: yo.nombre || caller.user.email, rol: yo.role, sede: yo.sede,
          pagina, tipo, resumen: String(inp.resumen || mensaje).slice(0, 500), detalle: String(inp.detalle || '').slice(0, 4000),
        }).select('id').single();
        if (error || !t) {
          resultados.push({ type: 'tool_result', tool_use_id: b.id, is_error: true, content: 'No se pudo guardar el ticket: ' + (error?.message || '') });
        } else {
          tickets.push(t.id);
          resultados.push({ type: 'tool_result', tool_use_id: b.id, content: `Ticket #${t.id} creado. Administración lo verá en su lista de pendientes.` });
        }
      }
      messages.push({ role: 'user', content: resultados });
    }

    // 5) Respuesta -------------------------------------------------------------
    let texto = (msg?.content || []).filter(b => b.type === 'text').map(b => (b as Anthropic.Beta.BetaTextBlock).text).join('\n').trim();
    if (msg?.stop_reason === 'refusal') texto = 'No puedo ayudar con esa consulta. Si es algo del club, escríbala de otra forma o consulte a Administración.';
    if (!texto) texto = tickets.length ? `Listo, quedó el ticket #${tickets.join(', #')} para Administración.` : 'No pude responder. Intente de nuevo.';
    return json({ respuesta: texto, tickets, historial: messages });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
