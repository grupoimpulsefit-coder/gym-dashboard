// ════════════════════════════════════════════════════════════════════════
//  Edge Function: asistente  (Chloe)
//  Chat de ayuda dentro de la app: responde dudas del personal con el Manual
//  Operativo (manual.ts) y lo que se sabe de cómo funciona jykc.dev. Si la
//  respuesta no está, o el trámite necesita a Administración (anular una
//  venta, revisar un SINPE, un descuadre…), crea un ticket en
//  asistente_tickets (ver asistente.sql) para que Administración lo atienda.
//  Si la persona ya tiene una consulta pendiente del mismo asunto, le agrega
//  los datos nuevos en vez de crear otra.
//  A Administración (admin, admin_sedes, admin_g) además le acepta "agregá a tu
//  conocimiento que…": lo guarda en asistente_conocimiento y lo usa desde la
//  siguiente consulta de cualquier persona.
//
//  Además de { mensaje, historial, pagina } acepta:
//    { accion: 'agregar', ticket, texto }  → botón "Agregar detalle" de Mis consultas
//    { accion: 'probar_push' }             → notificación de prueba a los teléfonos de quien llama
//
//  Secretos: ANTHROPIC_API_KEY (el mismo de analizar-datafono) y, para las
//  notificaciones push, VAPID_PUBLIC_KEY y VAPID_PRIVATE_KEY (la pública es la
//  misma que VAPID_PUBLIC en movil.html). Sin las VAPID el chat funciona igual.
//  Se publica con el nombre exacto: asistente  (incluye manual.ts y terminos.ts)
//    supabase functions deploy asistente
//  (SUPABASE_URL, SUPABASE_ANON_KEY y SUPABASE_SERVICE_ROLE_KEY ya vienen inyectadas.)
// ════════════════════════════════════════════════════════════════════════
import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Anthropic from 'npm:@anthropic-ai/sdk';
import webpush from 'npm:web-push@3.6.7';
import { MANUAL } from './manual.ts';
import { TERMINOS } from './terminos.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
// Haiku: responder sobre el manual no necesita más, y cuesta ~40 veces menos que Opus.
const MODEL = 'claude-haiku-5-5';
const MAX_MENSAJES = 40;          // historial que se acepta del navegador (unos 10 intercambios)
const MAX_HISTORIAL_BYTES = 300_000;
const TIPOS = ['duda', 'anular_venta', 'revisar_sinpe', 'descuadre_caja', 'error_app', 'otro'] as const;
const ADMIN_ROLES = ['admin', 'admin_sedes', 'admin_g'];

const MAPA_APP = `Módulos de jykc.dev (cada uno es una pantalla; se entra desde el menú principal):
• /caja — Cierre de Caja. Pestañas Cierre y Facturación. Abrir turno (denominaciones + inventario inicial), facturar productos/minita/eventos, cargar Informe de Ventas de WStudio, Reporte SINPE de Ridivi, foto del datáfono, conteo de inventario, opción de minita, recuadro verde «Para WStudio», cierre parcial y cierre final (definitivo; descargar el PDF antes).
• /gastos — Registrar gastos (necesitan factura y aprobación de Administración) y pagos de clases grupales / instructores de planta.
• /mediciones — Agenda semanal de mediciones en bloques de 15 minutos. Recepción agenda; el instructor o el coordinador marca la rutina (completa, incompleta o solo medición). Administración también puede marcarla.
• /inventario — Stock, precios y faltantes por sede. Solo Administración, coordinador (solo consulta) y admin_sucursal. Recepción NO tiene acceso a este módulo ni puede ver cantidades de stock en ninguna pantalla: el conteo de inventario de recepción (apertura y cierre en /caja) es a ciegas.
• /conciliacion — Auditoría SINPE: qué facturas tienen su SINPE y cuáles no.
• /rrhh — Mi Portal (para quien está en planilla): saldo y solicitud de vacaciones, día libre sin goce, incapacidades, citas médicas y comprobantes. Administración ve ahí Recursos Humanos.
• /planilla, /sedes, /comparativa, /otros, /nat — módulos de Administración (planilla quincenal, reportes por sede, rentabilidad de productos, academia de natación).
Sedes: 3 Ríos, Pinares, Sabanilla (gimnasio) y Natación (academia).
Roles: recepcion, admin_sucursal, instructor, coordinador, colaborador y Administración (admin, admin_sedes, admin_g).
Sistemas externos: WStudio (membresías y su caja), Ridivi (SINPE Móvil). La sesión se cierra sola tras un rato sin actividad; si una pantalla falla con "sesión vencida", volver a iniciar sesión.`;

const INSTRUCCIONES = `Te llamás Chloe y sos la asistente de ayuda de jykc.dev, el sistema de gestión de Fit and Train Fitness Club (Costa Rica). Te escribe el personal del club (recepcionistas, instructores, coordinadores) desde dentro de la app.

Cómo responder:
• Respondé solo con lo que dicen el Manual Operativo, los Términos y Condiciones y el mapa de la app de abajo, más las respuestas de Administración que se te den. No inventes pasos, montos, botones, plazos ni políticas.
• Tratá a la persona de usted, en español sencillo y corto. Para procedimientos, dá los pasos numerados tal como están en el manual y mencioná la sección (p. ej. "Manual 5, Paso 7").
• Si hay actualizaciones con fecha (sección "Actualización de procedimientos"), lo vigente es lo más reciente.
• Los Términos y Condiciones de abajo son el contrato y el reglamento que firma el cliente. Usalos para preguntas sobre las reglas del club (indumentaria, edad mínima, niños, casilleros, horario de las instalaciones, reposiciones, congelamientos, cambios de horario, conducta) y citá la cláusula o el número del reglamento. Las cláusulas del contrato hablan de la piscina y las clases de natación; no las apliques a las sedes de gimnasio salvo que el texto lo diga. Para los procedimientos internos del personal manda el Manual. Si el Manual y los Términos dicen cosas distintas sobre lo mismo, no elijas: explicá lo que dice cada uno y recomendá confirmarlo con Administración.
• Si la persona es de la sede Natación, aplicá también las diferencias para Natación. Las reglas que el manual marca como de Natación no se aplican a las sedes de gimnasio (3 Ríos, Pinares, Sabanilla). Si la persona no tiene sede fija y la respuesta cambia según la sede, preguntá de qué sede es el cliente.
• Cada mensaje de la persona llega con un bloque "CONTEXTO DE LA APP" que agrega el sistema (fecha y hora, quién pregunta, desde qué pantalla y sus consultas pendientes). Usalo como dato; no lo menciones salvo que haga falta. Para promociones y reglas con fechas, compará con esa fecha: si ya venció o todavía no empieza, decilo.

Cuándo crear un ticket (herramienta crear_ticket):
• Si la respuesta NO está en el manual ni en las respuestas de Administración: creá un ticket tipo "duda" con la pregunta, y decile que Administración la va a responder y que la verá en la pestaña "Mis consultas" de este chat. No adivines.
• Si pide algo que solo Administración puede hacer o autorizar (anular o corregir una venta o un cierre, revisar un SINPE que no aparece o no cuadra, un descuadre de caja, reembolsos, descuentos fuera de tarifa, excepciones al reglamento, un error de la app): creá el ticket con el tipo que corresponda. Nunca digas que la acción ya se hizo: decí que quedó solicitada.
• Antes de crear un ticket de trámite, pedí los datos que falten si son necesarios para que Administración actúe (fecha, sede, monto, número de factura o los últimos 6 dígitos de la referencia SINPE, nombre del cliente). Si ya los tiene, no los vuelvas a pedir.
• Un ticket por asunto. Si es una simple duda que sí está en el manual, respondé sin ticket.
• Si la persona trae más datos o una corrección sobre un asunto que ya tiene una consulta pendiente (lista "CONSULTAS PENDIENTES DE ESTA PERSONA"), usá agregar_a_ticket con ese número en vez de crear otro, y decile a qué número se agregó. Si no está claro que sea el mismo asunto, preguntale. Las consultas ya respondidas no se reabren: un asunto nuevo lleva ticket nuevo.
• Emergencias médicas o accidentes: indicá de inmediato el procedimiento del manual (sección 11) y que avise a Administración; no esperes a un ticket.
• No compartas datos personales de colaboradores, clientes ni dueños.
• Solo si el CONTEXTO DE LA APP dice que el rol es admin, admin_sedes o admin_g y la persona te pide que aprendas, agregues o actualices algo en tu conocimiento (un procedimiento nuevo, un cambio de precio, horario o política, una promoción…), usá guardar_conocimiento. Redactalo completo y claro, como lo tendrías que explicar al personal, con las fechas de vigencia si las dice. Si es ambiguo o le faltan datos, preguntale antes de guardar. Si reemplaza algo anterior, decilo en el contenido. Después confirmale qué quedó guardado y que lo puede ver o quitar en la pestaña "Conocimiento". A nadie más le guardes conocimiento: si otra persona te lo pide, decile que eso lo hace Administración.
• No tenés acceso al stock. Si alguien de recepción pregunta cuántas unidades hay de un producto, respondé solo que esa cantidad no se puede consultar (el conteo de recepción es a ciegas); no le indiques módulos ni formas de verla.`;

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
}, {
  name: 'agregar_a_ticket',
  description: 'Agrega datos nuevos a una consulta PENDIENTE de esta misma persona (de la lista de consultas pendientes), en vez de crear otro ticket del mismo asunto.',
  strict: true,
  input_schema: {
    type: 'object',
    additionalProperties: false,
    required: ['ticket', 'detalle'],
    properties: {
      ticket: { type: 'integer', description: 'Número de la consulta pendiente.' },
      detalle: { type: 'string', description: 'Lo nuevo que aporta la persona, completo y claro para Administración.' },
    },
  },
}];

// Solo se le ofrece a Administración (ver más abajo)
const TOOL_CONOCIMIENTO: Anthropic.Beta.BetaTool = {
  name: 'guardar_conocimiento',
  description: 'Guarda información nueva o actualizada que Administración te pide aprender. Desde la siguiente consulta la vas a tener igual que el manual.',
  strict: true,
  input_schema: {
    type: 'object',
    additionalProperties: false,
    required: ['tema', 'contenido'],
    properties: {
      tema: { type: 'string', description: 'Título corto, p. ej. "Precio de la mensualidad en Pinares".' },
      contenido: { type: 'string', description: 'La información completa, clara para el personal, con vigencia si la hay.' },
    },
  },
};

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

// ── Notificaciones push (Web Push) ───────────────────────────────────────
type Aviso = { title: string; body: string; tag?: string; url?: string };
async function enviarPush(admin: SupabaseClient, userIds: string[], aviso: Aviso) {
  const pub = Deno.env.get('VAPID_PUBLIC_KEY'), priv = Deno.env.get('VAPID_PRIVATE_KEY');
  if (!pub || !priv || !userIds.length) return 0;
  const { data: subs } = await admin.from('push_suscripciones').select('endpoint, p256dh, auth').in('user_id', userIds);
  if (!subs?.length) return 0;
  webpush.setVapidDetails(Deno.env.get('VAPID_SUBJECT') || 'https://jykc.dev', pub, priv);
  const r = await Promise.allSettled(subs.map(s =>
    webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify(aviso), { TTL: 86400 })
      .catch(async (e: { statusCode?: number }) => {
        // El teléfono desinstaló la app o revocó el permiso: la suscripción ya no sirve
        if (e?.statusCode === 404 || e?.statusCode === 410) await admin.from('push_suscripciones').delete().eq('endpoint', s.endpoint);
        throw e;
      })));
  return r.filter(x => x.status === 'fulfilled').length;
}
// A Administración, menos a quien hizo el cambio. Nunca rompe el chat si falla.
async function avisarAdmins(admin: SupabaseClient, salvo: string, aviso: Aviso) {
  try {
    const { data } = await admin.from('user_roles').select('id').in('role', ADMIN_ROLES);
    await enviarPush(admin, (data || []).map(a => a.id).filter(id => id !== salvo), aviso);
  } catch (_) { /* sin aviso */ }
}
const recorte = (s: string, n = 140) => (s.length > n ? s.slice(0, n - 1) + '…' : s);

// Agrega un detalle con la sesión de quien llama (la base valida que sea suya y siga pendiente)
async function agregarDetalle(asCaller: SupabaseClient, admin: SupabaseClient, uid: string, ticket: number, texto: string) {
  const { data, error } = await asCaller.rpc('asistente_agregar_detalle', { p_ticket: ticket, p_texto: texto });
  if (error) throw new Error(error.message);
  const t = data as { id: number; resumen: string; usuario: string; sede: string | null };
  await avisarAdmins(admin, uid, {
    title: `Chloe · Consulta #${t.id} actualizada`,
    body: recorte(`${t.usuario}${t.sede ? ' (' + t.sede + ')' : ''} agregó: ${texto}`),
    tag: 'ticket-' + t.id, url: '/movil?asistente=pend',
  });
  return t;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Método no permitido' }, 405);

  try {
    const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
    const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
    const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY');

    // 1) Quién pregunta: cualquier cuenta con rol en user_roles ---------------
    const token = (req.headers.get('Authorization') || '').replace('Bearer ', '').trim();
    if (!token) return json({ error: 'No autenticado' }, 401);
    const asCaller = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: `Bearer ${token}` } } });
    const { data: caller } = await asCaller.auth.getUser();
    if (!caller?.user) return json({ error: 'Sesión inválida' }, 401);
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE);
    const { data: yo } = await admin.from('user_roles').select('role, nombre, sede').eq('id', caller.user.id).single();
    if (!yo?.role) return json({ error: 'Sin permiso' }, 403);

    const body = await req.json().catch(() => ({}));

    // Acciones sin chat ---------------------------------------------------------
    if (body.accion === 'agregar') {
      try {
        const t = await agregarDetalle(asCaller, admin, caller.user.id, Number(body.ticket), String(body.texto || ''));
        return json({ ok: true, id: t.id });
      } catch (e) { return json({ error: (e as Error).message }, 400); }
    }
    if (body.accion === 'probar_push') {
      const n = await enviarPush(admin, [caller.user.id], { title: 'Chloe', body: 'Las notificaciones de consultas están activas en este teléfono.', tag: 'prueba', url: '/movil' });
      return json({ enviadas: n });
    }

    if (!ANTHROPIC_API_KEY) return json({ error: 'Falta configurar ANTHROPIC_API_KEY en los secretos de la función.' }, 500);

    // 2) Mensaje nuevo + historial que guarda el navegador ---------------------
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
    // Conocimiento que Administración le enseñó desde el chat (lo más nuevo manda)
    const { data: notas } = await admin.from('asistente_conocimiento')
      .select('tema, contenido, created_at').eq('activo', true)
      .order('created_at', { ascending: true }).limit(200);
    const conocimiento = (notas || []).map(n => `[${String(n.created_at).slice(0, 10)}] ${n.tema}\n${n.contenido}`).join('\n\n');
    const esAdmin = ADMIN_ROLES.includes(yo.role);

    // Consultas pendientes de quien pregunta: para agregarles datos en vez de duplicarlas
    const { data: abiertas } = await admin.from('asistente_tickets')
      .select('id, tipo, resumen, detalle, agregados, created_at').eq('user_id', caller.user.id).eq('estado', 'pendiente')
      .order('created_at', { ascending: false }).limit(10);
    const pendientes = (abiertas || []).map(t =>
      `#${t.id} (${t.tipo}, ${String(t.created_at).slice(0, 10)}): ${t.resumen}` +
      (t.detalle ? `\n   Detalle: ${recorte(String(t.detalle), 400)}` : '') +
      ((t.agregados || []).length ? `\n   Agregado después: ${(t.agregados as { texto: string }[]).map(a => recorte(a.texto, 200)).join(' | ')}` : '')).join('\n');

    // El bloque grande (instrucciones + mapa + manual) va primero y en caché; las respuestas
    // aprendidas, después. Lo que cambia en cada turno (quién pregunta, pantalla, consultas
    // pendientes) NO va en `system`: el modelo ata su razonamiento a todo lo anterior y un
    // `system` distinto en el turno siguiente da 400. Va como contexto dentro del mensaje nuevo.
    const system: Anthropic.Beta.BetaTextBlockParam[] = [
      { type: 'text', text: `${INSTRUCCIONES}\n\n═══ MAPA DE LA APP ═══\n${MAPA_APP}\n\n═══ MANUAL OPERATIVO ═══\n${MANUAL}\n\n═══ TÉRMINOS Y CONDICIONES Y REGLAMENTO (los firma el cliente) ═══\n${TERMINOS}`, cache_control: { type: 'ephemeral' } },
      { type: 'text', text: `═══ CONOCIMIENTO AGREGADO POR ADMINISTRACIÓN (vale igual que el manual; si choca, manda esto, y entre dos notas manda la más reciente) ═══\n${conocimiento || '(nada todavía)'}\n\n═══ RESPUESTAS DE ADMINISTRACIÓN (valen igual que el manual; si chocan, mandan estas) ═══\n${extra || '(ninguna todavía)'}` },
    ];
    const ahora = new Date().toLocaleString('es-CR', { timeZone: 'America/Costa_Rica', dateStyle: 'full', timeStyle: 'short' });
    const contexto = `═══ CONTEXTO DE LA APP ═══\nFecha y hora (Costa Rica): ${ahora}\nNombre: ${yo.nombre || caller.user.email}\nRol: ${yo.role}\nSede: ${yo.sede || 'sin sede fija'}\nPantalla abierta: ${pagina || 'menú principal'}\n\nCONSULTAS PENDIENTES DE ESTA PERSONA:\n${pendientes || '(ninguna)'}`;

    const messages: Anthropic.Beta.BetaMessageParam[] = [...historial,
      { role: 'user', content: [{ type: 'text', text: contexto }, { type: 'text', text: mensaje }] }];
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
          // Si el historial que manda el navegador no calza con el razonamiento guardado
          // (versión vieja, respuestas aprendidas nuevas), se descarta ese razonamiento en vez de dar 400.
          thinking: { type: 'adaptive', block_binding: { prefix_mismatch_behavior: 'drop_block' } } as Anthropic.Beta.BetaThinkingConfigParam,
          // Haiku no tiene respaldo automático (fallbacks): un rechazo se maneja abajo (stop_reason 'refusal').
          betas: ['thinking-binding-controls-2026-08-01'],
          system, tools: esAdmin ? [...TOOLS, TOOL_CONOCIMIENTO] : TOOLS, messages,
        });
      } catch (e) {
        if (e instanceof Anthropic.APIError) {
          console.error('asistente: error de la API', e.status, e.message);
          return json({ error: `El asistente no está disponible (${e.status ?? 'sin conexión'}). Intente de nuevo en un momento.` }, 502);
        }
        throw e;
      }
      messages.push({ role: 'assistant', content: msg.content });
      if (msg.stop_reason !== 'tool_use') break;

      const resultados: Anthropic.Beta.BetaToolResultBlockParam[] = [];
      for (const b of msg.content) {
        if (b.type !== 'tool_use') continue;
        if (b.name === 'agregar_a_ticket') {
          const inp = b.input as { ticket?: number; detalle?: string };
          try {
            const t = await agregarDetalle(asCaller, admin, caller.user.id, Number(inp.ticket), String(inp.detalle || ''));
            tickets.push(t.id);
            resultados.push({ type: 'tool_result', tool_use_id: b.id, content: `Se agregó a la consulta #${t.id}. Administración ya fue avisada.` });
          } catch (e) {
            resultados.push({ type: 'tool_result', tool_use_id: b.id, is_error: true, content: (e as Error).message });
          }
          continue;
        }
        if (b.name === 'guardar_conocimiento') {
          const inp = b.input as { tema?: string; contenido?: string };
          const tema = String(inp.tema || '').trim().slice(0, 200), contenido = String(inp.contenido || '').trim().slice(0, 6000);
          let falla = !esAdmin ? 'Solo Administración puede agregar conocimiento.' : !tema || !contenido ? 'Falta el tema o el contenido.' : '';
          if (!falla) {
            const { data: n, error } = await admin.from('asistente_conocimiento').insert({
              tema, contenido, creado_por: caller.user.id, autor: yo.nombre || caller.user.email,
            }).select('id').single();
            if (n) resultados.push({ type: 'tool_result', tool_use_id: b.id, content: `Guardado como nota #${n.id}. Se usa desde la próxima consulta.` });
            else falla = 'No se guardó: ' + (error?.message || '');
          }
          if (falla) resultados.push({ type: 'tool_result', tool_use_id: b.id, is_error: true, content: falla });
          continue;
        }
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
          await avisarAdmins(admin, caller.user.id, {
            title: `Chloe · Nueva consulta #${t.id}`,
            body: recorte(`${yo.nombre || caller.user.email}${yo.sede ? ' (' + yo.sede + ')' : ''}: ${String(inp.resumen || mensaje)}`),
            tag: 'ticket-' + t.id, url: '/movil?asistente=pend',
          });
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
