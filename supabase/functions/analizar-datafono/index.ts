// ════════════════════════════════════════════════════════════════════════
//  Edge Function: analizar-datafono
//  Recibe la foto de la auditoría/cierre del datáfono (POS) guardada en
//  Storage y usa Claude (visión) para leer el TOTAL de tarjeta del tiquete.
//  Devuelve el monto para compararlo contra "Total Tarjeta" del cierre.
//
//  Requiere un secreto con la API key de Anthropic (Supabase → Edge Functions
//  → Secrets):  ANTHROPIC_API_KEY = sk-ant-...
//  Se publica desde el panel de Supabase (Edge Functions → Deploy a new
//  function → Via Editor) con el nombre exacto: analizar-datafono
//  (SUPABASE_URL, SUPABASE_ANON_KEY y SUPABASE_SERVICE_ROLE_KEY ya vienen inyectadas.)
// ════════════════════════════════════════════════════════════════════════
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { encodeBase64 } from 'https://deno.land/std@0.224.0/encoding/base64.ts';
import Anthropic from 'npm:@anthropic-ai/sdk';
import { zodOutputFormat } from 'npm:@anthropic-ai/sdk/helpers/zod';
import { z } from 'npm:zod';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const ROLES_OK = ['recepcion', 'admin_sucursal', 'coordinador', 'admin_sedes', 'admin_g', 'admin'];
// Lectura simple de un número en una foto: el Haiku actual alcanza y cuesta centésimas de colón por foto.
const MODEL = 'claude-haiku-5-5';
const TIPOS_IMAGEN = ['image/jpeg', 'image/png', 'image/gif', 'image/webp'] as const;

// Respuesta con forma fija (structured outputs): no hay que buscar el JSON dentro del texto.
const Lectura = z.object({
  total: z.number().int().nullable(),          // colones, sin separadores; null si no se lee
  confianza: z.enum(['alta', 'media', 'baja']),
});

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

    // 2) Obtener la imagen: por path en Storage (cierres-caja) o base64 directo ----
    const body = await req.json().catch(() => ({}));
    let b64 = String(body.image_base64 || '');
    let mediaType = String(body.media_type || 'image/jpeg');
    if (!b64 && body.path) {
      // Siempre la carpeta de cierres: quien llama no elige otra (p. ej. documentos de RRHH)
      const { data: file, error: dlErr } = await admin.storage.from('cierres-caja').download(String(body.path));
      if (dlErr || !file) return json({ error: 'No se pudo leer la imagen del Storage: ' + (dlErr?.message || '') }, 400);
      mediaType = file.type || mediaType;
      b64 = encodeBase64(new Uint8Array(await file.arrayBuffer()));
    }
    if (!b64) return json({ error: 'No se recibió imagen.' }, 400);
    const tipo = (TIPOS_IMAGEN as readonly string[]).includes(mediaType)
      ? mediaType as typeof TIPOS_IMAGEN[number] : 'image/jpeg';

    // 3) Pedir a Claude que lea el total del tiquete -------------------------
    const prompt = 'Esta es la foto del comprobante de un datáfono (POS) de un gimnasio en Costa Rica ' +
      '(auditoría o cierre de lote). Identificá el MONTO TOTAL de las ventas con tarjeta: el gran total, en colones. ' +
      'Devolvé "total" como número entero en colones, sin separadores ni símbolo, y "confianza" según qué tan legible está. ' +
      'Si no se puede leer el total con seguridad, devolvé total null y confianza "baja".';
    const client = new Anthropic({ apiKey: ANTHROPIC_API_KEY });
    let msg;
    try {
      msg = await client.messages.parse({
        model: MODEL,
        max_tokens: 2048,   // incluye el razonamiento del modelo además de la respuesta corta
        output_config: { effort: 'low', format: zodOutputFormat(Lectura) },
        messages: [{ role: 'user', content: [
          { type: 'image', source: { type: 'base64', media_type: tipo, data: b64 } },
          { type: 'text', text: prompt },
        ] }],
      });
    } catch (e) {
      if (e instanceof Anthropic.APIError) return json({ error: `Error de la IA (${e.status ?? 'sin conexión'}): ${e.message}` }, 502);
      throw e;
    }

    // 4) Resultado ------------------------------------------------------------
    if (msg.stop_reason === 'refusal') return json({ total: null, confianza: 'baja', motivo: 'La IA no procesó la imagen.' });
    const p = msg.parsed_output;
    if (!p) return json({ total: null, confianza: 'baja', motivo: 'Respuesta incompleta de la IA.' });
    const total = p.total == null || !isFinite(p.total) ? null : Math.round(p.total);
    return json({ total, confianza: total == null ? 'baja' : p.confianza });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
