// ════════════════════════════════════════════════════════════════════════
//  Edge Function: finanzas-telegram
//  Bot de Telegram para registrar gastos e ingresos personales (finanzas.sql).
//
//  Las finanzas son compartidas por grupo (finanzas_v2.sql): el resumen suma lo
//  de todas las cuentas del grupo; cada registro queda a nombre de quien lo envió.
//
//  Mensajes que entiende (en un chat privado con el bot):
//    5000 almuerzo            → gasto (la categoría se detecta sola)
//    ayer 20 mil gasolina     → gasto con fecha de ayer
//    + 250000 salario         → ingreso (responde con el diezmo de 25 %)
//    /resumen                 → cómo va la semana
//    /deshacer                → borra lo último que registró por Telegram
//    /vincular CODIGO         → liga este chat a su cuenta (código en /finanzas → Ajustes)
//
//  Puesta en marcha (una vez):
//    1. En Telegram, hable con @BotFather → /newbot → copie el token del bot.
//    2. Supabase → Edge Functions → Secrets: FIN_TELEGRAM_SECRET = texto largo al azar
//       (solo letras, números, _ y -). El token del bot NO se guarda aquí: la
//       función responde dentro de la misma petición y nunca llama a Telegram.
//    3. Desplegar sin verificación JWT (Telegram no manda sesión de Supabase; la
//       función se protege con FIN_TELEGRAM_SECRET, que Telegram envía en cada mensaje):
//         supabase functions deploy finanzas-telegram --no-verify-jwt
//    4. Registrar el webhook abriendo en el navegador:
//       https://api.telegram.org/bot<TOKEN>/setWebhook?url=https://<PROJECT_REF>.supabase.co/functions/v1/finanzas-telegram&secret_token=<FIN_TELEGRAM_SECRET>&allowed_updates=["message"]
// ════════════════════════════════════════════════════════════════════════
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const SECRET = Deno.env.get('FIN_TELEGRAM_SECRET') || '';

const AYUDA = [
  'Escríbame así:',
  '• 5000 almuerzo — gasto',
  '• ayer 20 mil gasolina — gasto de ayer',
  '• + 250000 salario — ingreso',
  '• /resumen — cómo va la semana',
  '• /deshacer — borra lo último',
].join('\n');

const crc = (n: number) => '₡' + Math.round(n).toLocaleString('es-CR');

function hoyCR(offsetDias = 0): string {
  const d = new Date(Date.now() + offsetDias * 86400000);
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Costa_Rica' }).format(d);   // YYYY-MM-DD
}
function lunes(fecha: string): string {
  const d = new Date(fecha + 'T12:00:00Z');
  d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
  return d.toISOString().slice(0, 10);
}

// Monto dentro del texto: 5000 · 5.000 · 5,000 · ₡5000 · 5k · 5 mil · 2.5 mil
export function leerMonto(texto: string): { monto: number; resto: string } | null {
  const re = /₡?\s*(\d+(?:[.,]\d+)*)\s*(k|mil)?\b/i;
  const m = texto.match(re);
  if (!m) return null;
  let num = m[1];
  // Separadores de miles: grupos de 3 dígitos tras punto/coma
  if (/^\d{1,3}([.,]\d{3})+$/.test(num)) num = num.replace(/[.,]/g, '');
  else num = num.replace(',', '.');
  let monto = parseFloat(num);
  if (m[2]) monto *= 1000;
  if (!isFinite(monto) || monto <= 0) return null;
  const resto = (texto.slice(0, m.index) + ' ' + texto.slice(m.index! + m[0].length)).replace(/\s+/g, ' ').trim();
  return { monto: Math.round(monto * 100) / 100, resto };
}

function responder(chatId: number, text: string) {
  return new Response(JSON.stringify({ method: 'sendMessage', chat_id: chatId, text }), {
    headers: { 'Content-Type': 'application/json' },
  });
}
const ok = () => new Response('ok');

async function miembros(owner: string): Promise<string[]> {
  const { data: yo } = await db.from('fin_duenos').select('grupo').eq('user_id', owner).single();
  const { data } = await db.from('fin_duenos').select('user_id').eq('grupo', yo!.grupo);
  return (data || []).map((r) => r.user_id);
}

// Semana actual con arrastre (fin_semanas en finanzas_v2.sql)
async function semanaActual(grupo: string[]) {
  const sem = lunes(hoyCR());
  const { data } = await db.rpc('fin_semanas', { p_miembros: grupo });
  const fila = (data || []).find((r: any) => r.semana === sem);
  return { sem, fila: fila || { ingresos: 0, disponible: 0, gastos: 0, prestamos: 0, anterior: 0, queda: 0 } };
}

async function resumen(grupo: string[]): Promise<string> {
  const { sem, fila } = await semanaActual(grupo);
  const [gas, pend, pres] = await Promise.all([
    db.from('fin_gastos').select('monto, categoria').in('owner', grupo).eq('semana', sem),
    db.from('fin_ingresos').select('diezmo').in('owner', grupo).eq('entregado', false),
    db.from('fin_prestamos').select('tipo, persona, monto, fin_prestamo_pagos(monto)').in('owner', grupo),
  ]);
  const cats: Record<string, number> = {};
  for (const g of gas.data || []) cats[g.categoria] = (cats[g.categoria] || 0) + +g.monto;
  const lineasCat = Object.entries(cats).sort((a, b) => b[1] - a[1]).map(([c, v]) => `   ${c}: ${crc(v)}`);
  const porDiezmo = (pend.data || []).reduce((a, r) => a + +r.diezmo, 0);
  const lineasPres = (pres.data || []).map((p: any) => {
    const saldo = +p.monto - (p.fin_prestamo_pagos || []).reduce((a: number, x: any) => a + +x.monto, 0);
    if (saldo <= 0) return '';
    return p.tipo === 'preste' ? `   ${p.persona} le debe: ${crc(saldo)}` : `   Usted le debe a ${p.persona}: ${crc(saldo)}`;
  }).filter(Boolean);
  const ant = +fila.anterior;
  return [
    `📅 Semana del ${sem}`,
    ...(ant ? [`${ant < 0 ? '🔻 Faltante' : '➕ Sobrante'} de la semana anterior: ${crc(ant)}`] : []),
    `Ingresos: ${crc(+fila.ingresos)} (disponible ${crc(+fila.disponible)})`,
    ...(+fila.prestamos ? [`Préstamos (neto): ${crc(+fila.prestamos)}`] : []),
    `Gastado: ${crc(+fila.gastos)}`,
    ...lineasCat,
    `${+fila.queda < 0 ? '⚠️ Faltante' : 'Le queda'}: ${crc(+fila.queda)}`,
    ...(porDiezmo > 0 ? ['', `🙏 Diezmo por entregar: ${crc(porDiezmo)}`] : []),
    ...(lineasPres.length ? ['', 'Préstamos pendientes:', ...lineasPres] : []),
  ].join('\n');
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('ok');
  if (!SECRET || req.headers.get('X-Telegram-Bot-Api-Secret-Token') !== SECRET) {
    return new Response('unauthorized', { status: 401 });
  }
  const upd = await req.json().catch(() => ({}));
  const msg = upd.message;
  if (!msg?.chat || msg.chat.type !== 'private' || typeof msg.text !== 'string') return ok();
  const chatId: number = msg.chat.id;
  const texto = msg.text.trim();

  try {
    // ── Vincular este chat con la cuenta ───────────────────────────────────
    const vin = texto.match(/^\/(?:vincular|start)(?:@\w+)?\s+([A-Z0-9]{6,})$/i);
    if (vin) {
      const { data: c } = await db.from('fin_config').select('owner')
        .eq('telegram_codigo', vin[1].toUpperCase()).maybeSingle();
      if (!c) return responder(chatId, 'Código inválido o ya usado. Genere uno nuevo en /finanzas → Ajustes.');
      await db.from('fin_config').update({ telegram_chat_id: null }).eq('telegram_chat_id', chatId);
      await db.from('fin_config').update({ telegram_chat_id: chatId, telegram_codigo: null, updated_at: new Date().toISOString() })
        .eq('owner', c.owner);
      return responder(chatId, '✅ Chat vinculado.\n\n' + AYUDA);
    }

    // ── ¿De quién es este chat? ────────────────────────────────────────────
    const { data: cfg } = await db.from('fin_config').select('owner').eq('telegram_chat_id', chatId).maybeSingle();
    if (!cfg) return responder(chatId, 'Este chat no está vinculado. Abra /finanzas → Ajustes y envíe aquí: /vincular CODIGO');
    const { data: dueno } = await db.from('fin_duenos').select('user_id').eq('user_id', cfg.owner).maybeSingle();
    if (!dueno) return ok();
    const owner: string = cfg.owner;
    const grupo = await miembros(owner);

    if (/^\/(start|ayuda|help)\b/i.test(texto)) return responder(chatId, AYUDA);
    if (/^\/(resumen|semana)\b/i.test(texto)) return responder(chatId, await resumen(grupo));

    if (/^\/deshacer\b/i.test(texto)) {
      const [g, i] = await Promise.all([
        db.from('fin_gastos').select('id, monto, descripcion, created_at').eq('owner', owner).eq('origen', 'telegram')
          .order('created_at', { ascending: false }).limit(1).maybeSingle(),
        db.from('fin_ingresos').select('id, monto, descripcion, created_at').eq('owner', owner).eq('origen', 'telegram')
          .order('created_at', { ascending: false }).limit(1).maybeSingle(),
      ]);
      const ult = [g.data && { t: 'fin_gastos', ...g.data }, i.data && { t: 'fin_ingresos', ...i.data }]
        .filter(Boolean).sort((a: any, b: any) => (a.created_at < b.created_at ? 1 : -1))[0] as any;
      if (!ult) return responder(chatId, 'No hay nada registrado por Telegram para borrar.');
      await db.from(ult.t).delete().eq('id', ult.id).eq('owner', owner);
      return responder(chatId, `🗑 Borrado: ${ult.t === 'fin_gastos' ? 'gasto' : 'ingreso'} ${crc(ult.monto)} ${ult.descripcion || ''}`.trim());
    }

    // ── Fecha: "ayer" / "anteayer" ─────────────────────────────────────────
    let t = texto, fecha = hoyCR();
    if (/\banteayer\b/i.test(t)) { fecha = hoyCR(-2); t = t.replace(/\banteayer\b/i, ''); }
    else if (/\bayer\b/i.test(t)) { fecha = hoyCR(-1); t = t.replace(/\bayer\b/i, ''); }

    // ── Ingreso ────────────────────────────────────────────────────────────
    const esIngreso = /^\s*(\+|ingreso\b)/i.test(t);
    if (esIngreso) t = t.replace(/^\s*(\+|ingreso\b)/i, '');

    const p = leerMonto(t);
    if (!p) return responder(chatId, 'No encontré el monto. ' + AYUDA);
    const descripcion = p.resto || null;

    if (esIngreso) {
      const { data, error } = await db.from('fin_ingresos')
        .insert({ owner, fecha, monto: p.monto, descripcion, origen: 'telegram' })
        .select('monto, diezmo, disponible').single();
      if (error) throw error;
      const { fila } = await semanaActual(grupo);
      return responder(chatId, [
        `✅ Ingreso ${crc(data.monto)}${descripcion ? ' · ' + descripcion : ''}`,
        `🙏 Diezmo 25%: ${crc(data.diezmo)}`,
        `💵 Disponible 75%: ${crc(data.disponible)}`,
        `${+fila.queda < 0 ? '⚠️ Faltante' : 'Le queda'} esta semana: ${crc(+fila.queda)}`,
      ].join('\n'));
    }

    const { data, error } = await db.from('fin_gastos')
      .insert({ owner, fecha, monto: p.monto, descripcion, origen: 'telegram' })
      .select('monto, categoria').single();
    if (error) throw error;
    const { fila } = await semanaActual(grupo);
    return responder(chatId,
      `✅ Gasto ${crc(data.monto)} · ${data.categoria}${descripcion ? ' · ' + descripcion : ''}` +
      (fecha !== hoyCR() ? ` (${fecha})` : '') +
      `\n${+fila.queda < 0 ? '⚠️ Faltante' : 'Le queda'} esta semana: ${crc(+fila.queda)}`);
  } catch (e) {
    console.error(e);
    return responder(chatId, '⚠️ No se pudo registrar. Intente de nuevo.');
  }
});
