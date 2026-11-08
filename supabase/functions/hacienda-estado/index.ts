// ════════════════════════════════════════════════════════════════════════
//  Edge Function: hacienda-estado
//  Consulta en Hacienda (API de comprobantes electrónicos) el estado de una
//  factura por su clave de 50 dígitos: aceptada, rechazada o en proceso.
//  La usa Gastos → «Cargar factura XML» / «Por aprobar» (pagos_instructores.js).
//
//  Entra con las credenciales de API de la razón social a cuyo nombre viene la
//  factura (la sede, ver sedes_fiscal). Se guardan como secretos de la función
//  (Supabase → Edge Functions → Secrets), uno por cédula jurídica, solo dígitos:
//    HACIENDA_USUARIO_3101789494 = cpj-3-101-789494@prod.comprobanteselectronicos.go.cr
//    HACIENDA_CLAVE_3101789494   = contraseña generada en Tribu-CR
//  (NO la llave criptográfica ni su PIN: esos son para firmar, no para consultar.)
//  Las credenciales nunca salen de aquí: al navegador solo vuelve el estado.
//
//  Acciones:
//    { accion: 'estado', clave, receptor }  → estado de la factura
//    { accion: 'probar', receptor }         → solo prueba que las credenciales entren
//
//  Se publica con el nombre exacto: hacienda-estado
//    supabase functions deploy hacienda-estado
// ════════════════════════════════════════════════════════════════════════
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { decodeBase64 } from 'https://deno.land/std@0.224.0/encoding/base64.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const ROLES_OK = ['recepcion', 'admin_sucursal', 'coordinador', 'admin_sedes', 'admin_g', 'admin'];
const IDP = 'https://idp.comprobanteselectronicos.go.cr/auth/realms/rut/protocol/openid-connect/token';
const API = 'https://api.comprobanteselectronicos.go.cr/recepcion/v1/recepcion/';
const digitos = (s: unknown) => String(s ?? '').replace(/\D/g, '');

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

// Token de Hacienda (dura unos minutos; se pide uno por consulta)
async function token(usuario: string, clave: string): Promise<string> {
  const r = await fetch(IDP, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'password', client_id: 'api-prod', username: usuario, password: clave }),
    signal: AbortSignal.timeout(12000),
  });
  if (r.status === 400 || r.status === 401) throw new Error('credenciales');
  if (!r.ok) throw new Error('Hacienda respondió ' + r.status + ' al iniciar sesión');
  const j = await r.json();
  if (!j.access_token) throw new Error('Hacienda no entregó el acceso');
  return j.access_token as string;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Método no permitido' }, 405);
  try {
    const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
    const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
    const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

    // Quién consulta: solo cuentas que manejan gastos
    const jwt = (req.headers.get('Authorization') || '').replace('Bearer ', '').trim();
    if (!jwt) return json({ error: 'No autenticado' }, 401);
    const asCaller = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: `Bearer ${jwt}` } } });
    const { data: caller } = await asCaller.auth.getUser();
    if (!caller?.user) return json({ error: 'Sesión inválida' }, 401);
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE);
    const { data: yo } = await admin.from('user_roles').select('role').eq('id', caller.user.id).single();
    if (!yo || !ROLES_OK.includes(yo.role)) return json({ error: 'Sin permiso' }, 403);

    const body = await req.json().catch(() => ({}));
    const accion = body.accion === 'probar' ? 'probar' : 'estado';
    const ced = digitos(body.receptor);

    // Solo razones sociales de las sedes (no se consulta con otras cédulas)
    const { data: sedes } = await admin.from('sedes_fiscal').select('sede, cedula_juridica');
    const sede = (sedes || []).find(s => ced && digitos(s.cedula_juridica) === ced);
    if (!sede) return json({ estado: 'sin_sede', detalle: 'La cédula jurídica no es de ninguna sede configurada.' });

    const usuario = Deno.env.get('HACIENDA_USUARIO_' + ced), pass = Deno.env.get('HACIENDA_CLAVE_' + ced);
    if (!usuario || !pass) {
      return json({ estado: 'sin_credenciales', sede: sede.sede,
        detalle: `Faltan los secretos HACIENDA_USUARIO_${ced} y HACIENDA_CLAVE_${ced} en Supabase (Edge Functions → Secrets).` });
    }

    let tk: string;
    try { tk = await token(usuario, pass); }
    catch (e) {
      const m = (e as Error).message;
      return json(m === 'credenciales'
        ? { estado: 'credenciales_invalidas', sede: sede.sede, detalle: `Hacienda no aceptó el usuario y la contraseña de API de ${sede.sede}. Revise que sean los generados en Tribu-CR.` }
        : { estado: 'error', sede: sede.sede, detalle: 'No se pudo entrar a Hacienda: ' + m });
    }
    if (accion === 'probar') return json({ estado: 'conectado', sede: sede.sede, detalle: `Conexión con Hacienda correcta (${sede.sede}).` });

    const clave = digitos(body.clave);
    if (!/^\d{50}$/.test(clave)) return json({ error: 'Clave de factura inválida' }, 400);
    const r = await fetch(API + clave, { headers: { Authorization: 'Bearer ' + tk }, signal: AbortSignal.timeout(12000) });
    const causa = r.headers.get('X-Error-Cause') || '';
    if (r.status === 404) return json({ estado: 'no_encontrado', sede: sede.sede, detalle: causa || 'Hacienda no tiene registrada esta clave.' });
    if (r.status === 401 || r.status === 403) return json({ estado: 'sin_permiso', sede: sede.sede, detalle: causa || 'Hacienda no permite consultar esta factura con las credenciales de la sede.' });
    if (!r.ok) return json({ estado: 'error', sede: sede.sede, detalle: `Hacienda respondió ${r.status}${causa ? ': ' + causa : ''}` });

    const j = await r.json();
    const estado = String(j['ind-estado'] || '').toLowerCase() || 'desconocido';
    // El motivo de un rechazo viene dentro de la respuesta de Hacienda (XML en base64)
    let detalle = '';
    if (j['respuesta-xml']) {
      try {
        const xml = new TextDecoder().decode(decodeBase64(String(j['respuesta-xml'])));
        const m = xml.match(/<(?:\w+:)?DetalleMensaje>([\s\S]*?)<\/(?:\w+:)?DetalleMensaje>/);
        if (m) detalle = m[1].replace(/\s+/g, ' ').trim().slice(0, 500);
      } catch (_) { /* sin detalle */ }
    }
    return json({ estado, sede: sede.sede, detalle, fecha: j.fecha || null });
  } catch (e) {
    const m = (e as Error)?.name === 'TimeoutError' ? 'Hacienda no respondió a tiempo.' : String((e as Error)?.message || e);
    return json({ estado: 'error', detalle: m });
  }
});
