// ════════════════════════════════════════════════════════════════════════
//  Edge Function: analizar-datafono
//  Recibe la foto de la auditoría/cierre del datáfono (POS) guardada en
//  Storage y usa Claude (visión) para leer el TOTAL de tarjeta del tiquete.
//  Devuelve el monto para compararlo contra "Total Tarjeta" del cierre.
//
//  Requiere un secreto con la API key de Anthropic:
//    supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
//  Deploy:
//    supabase functions deploy analizar-datafono
//  (SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY ya vienen inyectadas.)
// ════════════════════════════════════════════════════════════════════════
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { encodeBase64 } from 'https://deno.land/std@0.224.0/encoding/base64.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const ROLES_OK = ['recepcion', 'admin_sucursal', 'admin_sedes', 'admin_g', 'admin'];
const MODEL = 'claude-haiku-4-5-20251001';

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

    // 1) Verificar que quien llama tenga un rol de caja ----------------------
    const token = (req.headers.get('Authorization') || '').replace('Bearer ', '').trim();
    if (!token) return json({ error: 'No autenticado' }, 401);
    const asCaller = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: `Bearer ${token}` } } });
    const { data: caller } = await asCaller.auth.getUser();
    if (!caller?.user) return json({ error: 'Sesión inválida' }, 401);
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE);
    const { data: rolRow } = await admin.from('user_roles').select('role').eq('id', caller.user.id).single();
    if (!rolRow || !ROLES_OK.includes(rolRow.role)) return json({ error: 'Sin permiso' }, 403);

    // 2) Obtener la imagen: por {bucket, path} en Storage o base64 directo ----
    const body = await req.json().catch(() => ({}));
    let b64 = String(body.image_base64 || '');
    let mediaType = String(body.media_type || 'image/jpeg');
    if (!b64 && body.path) {
      const bucket = String(body.bucket || 'cierres-caja');
      const { data: file, error: dlErr } = await admin.storage.from(bucket).download(String(body.path));
      if (dlErr || !file) return json({ error: 'No se pudo leer la imagen del Storage: ' + (dlErr?.message || '') }, 400);
      mediaType = file.type || mediaType;
      b64 = encodeBase64(new Uint8Array(await file.arrayBuffer()));
    }
    if (!b64) return json({ error: 'No se recibió imagen.' }, 400);

    // 3) Pedir a Claude que lea el total del tiquete -------------------------
    const prompt = 'Esta es la foto del comprobante de un datáfono (POS) de un gimnasio en Costa Rica ' +
      '(auditoría o cierre de lote). Identificá el MONTO TOTAL de las ventas con tarjeta (el gran total, en colones). ' +
      'Respondé ÚNICAMENTE con un JSON válido en una sola línea, sin texto extra, con esta forma: ' +
      '{"total": <numero entero en colones sin separadores ni símbolo>, "confianza": <"alta"|"media"|"baja">}. ' +
      'Si no lográs leer el total, usá {"total": null, "confianza": "baja"}.';
    const aiRes = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': ANTHROPIC_API_KEY, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({
        model: MODEL, max_tokens: 200,
        messages: [{ role: 'user', content: [
          { type: 'image', source: { type: 'base64', media_type: mediaType, data: b64 } },
          { type: 'text', text: prompt },
        ] }],
      }),
    });
    const aiData = await aiRes.json().catch(() => ({}));
    if (!aiRes.ok) return json({ error: 'Error de la IA: ' + (aiData?.error?.message || aiRes.status) }, 502);
    const text = (aiData?.content?.[0]?.text || '').trim();

    // 4) Parsear el JSON / número --------------------------------------------
    let total: number | null = null, confianza = 'baja';
    try {
      const m = text.match(/\{[\s\S]*\}/);
      if (m) { const p = JSON.parse(m[0]); total = p.total == null ? null : Math.round(Number(p.total)); confianza = p.confianza || 'media'; }
    } catch (_) { /* fallback abajo */ }
    if (total == null) { const digits = text.replace(/[^\d]/g, ''); if (digits) total = parseInt(digits, 10); }
    if (total != null && !isFinite(total)) total = null;

    return json({ total, confianza, raw: text });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
