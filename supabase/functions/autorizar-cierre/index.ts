// ════════════════════════════════════════════════════════════════════════
//  Edge Function: autorizar-cierre
//  Cerrar caja sin Informe de Ventas al día (ver autorizaciones_cierre.sql):
//    { accion: 'solicitar', cierre, tipo, motivo, generado } → pide la autorización y
//        avisa por push a Administración
//    { accion: 'resolver', solicitud, aprobar, nota } → un admin la aprueba o rechaza
//        y se avisa por push a quien la pidió
//  Los permisos y las reglas los valida la base (las funciones se llaman como
//  quien llama). Si el push falla, la solicitud queda igual: Administración la ve
//  en el aviso de arriba de la caja.
//  Secretos: VAPID_PUBLIC_KEY y VAPID_PRIVATE_KEY (los mismos de `asistente`).
//    supabase functions deploy autorizar-cierre
// ════════════════════════════════════════════════════════════════════════
import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.119.0';
import webpush from 'npm:web-push@3.6.7';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const ADMIN_ROLES = ['admin', 'admin_sedes', 'admin_g'];

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}
const recorte = (s: string, n = 180) => (s.length > n ? s.slice(0, n - 1) + '…' : s);
const hora = (iso: string | null) => iso
  ? new Date(iso).toLocaleTimeString('es-CR', { hour: 'numeric', minute: '2-digit', timeZone: 'America/Costa_Rica' }) : '';

// Igual que en `asistente`
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
        if (e?.statusCode === 404 || e?.statusCode === 410) await admin.from('push_suscripciones').delete().eq('endpoint', s.endpoint);
        throw e;
      })));
  return r.filter(x => x.status === 'fulfilled').length;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Método no permitido' }, 405);
  try {
    const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
    const token = (req.headers.get('Authorization') || '').replace('Bearer ', '').trim();
    if (!token) return json({ error: 'No autenticado' }, 401);
    const asCaller = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: `Bearer ${token}` } } });
    const { data: caller } = await asCaller.auth.getUser();
    if (!caller?.user) return json({ error: 'Sesión inválida' }, 401);
    const admin = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: yo } = await admin.from('user_roles').select('nombre').eq('id', caller.user.id).maybeSingle();
    const body = await req.json().catch(() => ({}));

    if (body.accion === 'solicitar') {
      const { data, error } = await asCaller.rpc('solicitar_autorizacion_cierre', {
        p_cierre: String(body.cierre || ''), p_tipo: String(body.tipo || ''), p_motivo: String(body.motivo || ''),
        p_generado: body.generado ? String(body.generado) : null });
      if (error) return json({ error: error.message }, 400);
      const a = data as { id: number; sede: string; turno_num: number | null; tipo: string; motivo: string; informe_generado: string | null; solicitante: string };
      const que = a.tipo === 'sin_informe' ? 'sin Informe de Ventas' : `con un Informe de Ventas de las ${hora(a.informe_generado) || '¿?'}`;
      let avisados = 0;
      try {
        const { data: ads } = await admin.from('user_roles').select('id').in('role', ADMIN_ROLES);
        avisados = await enviarPush(admin, (ads || []).map(x => x.id).filter(id => id !== caller.user.id), {
          title: `Autorizar cierre · ${a.sede}${a.turno_num ? ' turno ' + a.turno_num : ''}`,
          body: recorte(`${a.solicitante} pide cerrar ${que}. Motivo: ${a.motivo}`),
          tag: 'autcierre-' + a.id, url: '/caja?autorizar=' + a.id,
        });
      } catch (_) { /* sin aviso */ }
      return json({ ok: true, id: a.id, avisados });
    }

    if (body.accion === 'resolver') {
      const { data, error } = await asCaller.rpc('resolver_autorizacion_cierre', {
        p_id: Number(body.solicitud), p_aprobar: body.aprobar === true, p_nota: body.nota ? String(body.nota) : null });
      if (error) return json({ error: error.message }, 400);
      const r = data as { id: number; estado: string; nota: string | null; sede: string; solicitado_por: string | null };
      const txt = r.estado === 'aprobada' ? 'aprobada: ya puede cerrar el turno'
        : r.estado === 'rechazada' ? 'rechazada: descargue el Informe de Ventas y cárguelo' : 'vencida: el turno ya se había cerrado';
      if (r.solicitado_por && r.solicitado_por !== caller.user.id) {
        await enviarPush(admin, [r.solicitado_por], {
          title: `Cierre de caja · ${r.sede}`,
          body: recorte(`Autorización ${txt}.${r.nota ? ' ' + r.nota : ''} (${yo?.nombre || caller.user.email})`),
          tag: 'autcierre-' + r.id, url: '/caja',
        }).catch(() => 0);
      }
      return json({ ok: true, estado: r.estado, nota: r.nota });
    }

    return json({ error: 'Acción desconocida' }, 400);
  } catch (e) {
    return json({ error: (e as Error).message }, 500);
  }
});
