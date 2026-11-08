// ════════════════════════════════════════════════════════════════════════
//  Edge Function: finanzas-telegram
//  Bot de Telegram para registrar gastos e ingresos personales (finanzas.sql).
//
//  Mensajes que entiende (en un chat privado con el bot):
//    5000 almuerzo            → gasto (la categoría se detecta sola)
//    ayer 20 mil gasolina     → gasto con fecha de ayer
//    r3 15000 ofrenda         → gasto que sale del rubro 3 del segundo diezmo
//    + 250000 salario         → ingreso (responde con el reparto del diezmo)
//    /resumen                 → cómo va la semana
//    /deshacer                → borra lo último que registró por Telegram
//    /vincular CODIGO         → liga este chat a su cuenta (código en /finanzas → Ajustes)
//
//  Deploy (una vez):
//    1. En Telegram, hable con @BotFather → /newbot → copie el token.
//    2. supabase secrets set FIN_TELEGRAM_TOKEN=<token> FIN_TELEGRAM_SECRET=<texto-largo-al-azar>
//    3. supabase functions deploy finanzas-telegram --no-verify-jwt
//       (Telegram no manda sesión de Supabase; la función se protege con el
//        secreto del paso 2, que Telegram envía en cada mensaje.)
//    4. Registrar el webhook (una vez, desde el navegador o curl):
//       https://api.telegram.org/bot<token>/setWebhook?url=https://<PROJECT_REF>.supabase.co/functions/v1/finanzas-telegram&secret_token=<FIN_TELEGRAM_SECRET>
// ════════════════════════════════════════════════════════════════════════
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const SECRET = Deno.env.get('FIN_TELEGRAM_SECRET') || '';

const AYUDA = [
  'Escríbame así:',
  '• 5000 almuerzo — gasto',
  '• ayer 20 mil gasolina — gasto de ayer',
  '• r3 15000 ofrenda — gasto del rubro 3 (segundo diezmo)',
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

async function resumen(owner: string): Promise<string> {
  const sem = lunes(hoyCR());
  const [ing, gas, ingT, gasT, pend, cfg] = await Promise.all([
    db.from('fin_ingresos').select('monto, disponible').eq('owner', owner).eq('semana', sem),
    db.from('fin_gastos').select('monto, categoria, rubro').eq('owner', owner).eq('semana', sem),
    db.from('fin_ingresos').select('disponible, segundo_diezmo').eq('owner', owner),
    db.from('fin_gastos').select('monto, rubro').eq('owner', owner),
    db.from('fin_ingresos').select('diezmo, primicia').eq('owner', owner).eq('entregado', false),
    db.from('fin_config').select('rubros').eq('owner', owner).maybeSingle(),
  ]);
  const sum = (rows: any[] | null, f: (r: any) => number) => (rows || []).reduce((a, r) => a + f(r), 0);
  const ingresoSem = sum(ing.data, (r) => +r.monto);
  const dispSem = sum(ing.data, (r) => +r.disponible);
  const gastoSem = sum(gas.data, (r) => (r.rubro ? 0 : +r.monto));
  const saldo = sum(ingT.data, (r) => +r.disponible) - sum(gasT.data, (r) => (r.rubro ? 0 : +r.monto));
  const porDiezmo = sum(pend.data, (r) => +r.diezmo + +r.primicia);

  const cats: Record<string, number> = {};
  for (const g of gas.data || []) if (!g.rubro) cats[g.categoria] = (cats[g.categoria] || 0) + +g.monto;
  const lineasCat = Object.entries(cats).sort((a, b) => b[1] - a[1]).map(([c, v]) => `   ${c}: ${crc(v)}`);

  const rubros: string[] = cfg.data?.rubros || [];
  const porRubro = sum(ingT.data, (r) => +r.segundo_diezmo) / 7;
  const lineasRubro = rubros.map((n, i) => {
    const usado = sum(gasT.data, (r) => (r.rubro === i + 1 ? +r.monto : 0));
    return `   ${i + 1}. ${n}: ${crc(porRubro - usado)}`;
  });

  return [
    `📅 Semana del ${sem}`,
    `Ingresos: ${crc(ingresoSem)} (disponible ${crc(dispSem)})`,
    `Gastado: ${crc(gastoSem)}`,
    ...(lineasCat.length ? lineasCat : []),
    `Le queda esta semana: ${crc(dispSem - gastoSem)}`,
    '',
    `💰 Saldo acumulado: ${crc(saldo)}`,
    ...(porDiezmo > 0 ? [`🙏 Diezmo + primicia por entregar: ${crc(porDiezmo)}`] : []),
    ...(rubros.length ? ['', 'Segundo diezmo (saldo por rubro):', ...lineasRubro] : []),
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

    if (/^\/(start|ayuda|help)\b/i.test(texto)) return responder(chatId, AYUDA);
    if (/^\/(resumen|semana)\b/i.test(texto)) return responder(chatId, await resumen(owner));

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

    // ── Rubro del segundo diezmo: r3 / rubro 3 ─────────────────────────────
    let rubro: number | null = null;
    const rm = t.match(/\b(?:rubro\s*|r)([1-7])\b/i);
    if (!esIngreso && rm) { rubro = +rm[1]; t = t.replace(rm[0], ''); }

    const p = leerMonto(t);
    if (!p) return responder(chatId, 'No encontré el monto. ' + AYUDA);
    const descripcion = p.resto || null;

    if (esIngreso) {
      const { data, error } = await db.from('fin_ingresos')
        .insert({ owner, fecha, monto: p.monto, descripcion, origen: 'telegram' })
        .select('monto, diezmo, primicia, segundo_diezmo, disponible').single();
      if (error) throw error;
      return responder(chatId, [
        `✅ Ingreso ${crc(data.monto)}${descripcion ? ' · ' + descripcion : ''}`,
        `🙏 Diezmo 10%: ${crc(data.diezmo)}`,
        `🌱 Primicia 5%: ${crc(data.primicia)}`,
        `📦 Segundo diezmo 10%: ${crc(data.segundo_diezmo)} (${crc(data.segundo_diezmo / 7)} × 7 rubros)`,
        `💵 Disponible 75%: ${crc(data.disponible)}`,
      ].join('\n'));
    }

    const { data, error } = await db.from('fin_gastos')
      .insert({ owner, fecha, monto: p.monto, descripcion, rubro, origen: 'telegram' })
      .select('monto, categoria').single();
    if (error) throw error;
    const sem = lunes(hoyCR());
    const [ing, gas] = await Promise.all([
      db.from('fin_ingresos').select('disponible').eq('owner', owner).eq('semana', sem),
      db.from('fin_gastos').select('monto').eq('owner', owner).eq('semana', sem).is('rubro', null),
    ]);
    const queda = (ing.data || []).reduce((a, r) => a + +r.disponible, 0) - (gas.data || []).reduce((a, r) => a + +r.monto, 0);
    return responder(chatId,
      `✅ Gasto ${crc(data.monto)} · ${data.categoria}${rubro ? ` · rubro ${rubro}` : ''}${descripcion ? ' · ' + descripcion : ''}` +
      (fecha !== hoyCR() ? ` (${fecha})` : '') +
      `\nLe queda esta semana: ${crc(queda)}`);
  } catch (e) {
    console.error(e);
    return responder(chatId, '⚠️ No se pudo registrar. Intente de nuevo.');
  }
});
