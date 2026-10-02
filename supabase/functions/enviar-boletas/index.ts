// ════════════════════════════════════════════════════════════════════════
//  Edge Function: enviar-boletas
//  Envía por correo (Gmail) la boleta de pago de cada colaborador de una
//  quincena YA CERRADA en planilla.html.
//
//  · Solo un administrador (admin / admin_sedes) puede llamarla.
//  · El PDF de la boleta lo genera el navegador (mismo diseño que la descarga),
//    pero el DESTINATARIO y los montos del correo salen de la base de datos:
//    el correo de la ficha en `empleados` y el cierre en `planilla_periodos`.
//    Así nadie puede desviar una boleta a otro correo desde el navegador.
//  · Cada intento queda registrado en `planilla_boletas_envios`.
//
//  Secrets (Supabase → Edge Functions → Secrets, o por CLI):
//    supabase secrets set GMAIL_USER=planillas@gmail.com
//    supabase secrets set GMAIL_APP_PASSWORD="abcd efgh ijkl mnop"
//    supabase secrets set MAIL_FROM_NAME="Impulse Fit · Planillas"   (opcional)
//  La contraseña es una "contraseña de aplicación" de Google (requiere tener
//  activada la verificación en 2 pasos en esa cuenta), NO la contraseña normal.
//
//  Deploy:
//    supabase functions deploy enviar-boletas
// ════════════════════════════════════════════════════════════════════════
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import nodemailer from 'npm:nodemailer@6.9.14';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const MAX_POR_LLAMADA = 15;   // el navegador manda en tandas para no pasar el tiempo límite

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}
const crc = (n: number) => '₡' + Math.round(Number(n) || 0).toLocaleString('es-CR');
const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));

function cuerpoHtml(l: any, etiqueta: string, sede: string) {
  const fila = (t: string, v: number, signo = '') =>
    v ? `<tr><td style="padding:6px 0;color:#555;">${t}</td><td style="padding:6px 0;text-align:right;">${signo}${crc(v)}</td></tr>` : '';
  return `
  <div style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;max-width:520px;color:#1c1c1e;">
    <p>Hola ${esc(String(l.nombre || '').split(' ')[0])},</p>
    <p>Adjuntamos su <b>boleta de pago</b> de la ${esc(etiqueta)} (${esc(sede)}).</p>
    <table style="width:100%;border-collapse:collapse;font-size:14px;border-top:1px solid #ddd;margin-top:8px;">
      ${fila('Salario de la quincena', l.base)}
      ${fila('Feriados trabajados', l.feriado, '+')}
      ${fila('Bonos', l.bono, '+')}
      ${fila('Incapacidad (días rebajados)', l.incap, '−')}
      ${fila('Días sin goce de salario', l.sinGoce, '−')}
      ${fila('CCSS (trabajador)', l.ccss, '−')}
      ${fila('Subsidio de incapacidad', l.subsidio, '+')}
      ${fila('Otras deducciones', l.deduccion, '−')}
      <tr><td style="padding:10px 0;border-top:1px solid #ddd;font-weight:700;">Neto depositado</td>
          <td style="padding:10px 0;border-top:1px solid #ddd;text-align:right;font-weight:700;color:#1e8449;">${crc(l.neto)}</td></tr>
    </table>
    <p style="font-size:13px;color:#666;margin-top:16px;">Si tiene alguna consulta sobre su pago, comuníquese con administración.<br>Este es un correo automático, por favor no responda a esta dirección.</p>
  </div>`;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Método no permitido' }, 405);

  try {
    const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
    const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
    const GMAIL_USER = Deno.env.get('GMAIL_USER');
    const GMAIL_PASS = Deno.env.get('GMAIL_APP_PASSWORD');
    const FROM_NAME = Deno.env.get('MAIL_FROM_NAME') || 'Planillas';
    if (!GMAIL_USER || !GMAIL_PASS) return json({ error: 'Falta configurar GMAIL_USER y GMAIL_APP_PASSWORD en los secrets de la función' }, 500);

    // 1) Solo administradores ------------------------------------------------
    const token = (req.headers.get('Authorization') || '').replace('Bearer ', '').trim();
    if (!token) return json({ error: 'No autenticado' }, 401);
    const asCaller = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: `Bearer ${token}` } } });
    const { data: caller, error: cErr } = await asCaller.auth.getUser();
    if (cErr || !caller?.user) return json({ error: 'Sesión inválida' }, 401);

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE);
    const { data: rolRow } = await admin.from('user_roles').select('role').eq('id', caller.user.id).single();
    if (!rolRow || !['admin', 'admin_sedes'].includes(rolRow.role)) return json({ error: 'Solo un administrador puede enviar boletas' }, 403);

    // 2) Payload --------------------------------------------------------------
    const body = await req.json().catch(() => ({}));
    const sede = String(body.sede || '');
    const periodo = String(body.periodo || '');
    const etiqueta = String(body.etiqueta || periodo);
    const boletas: { empleado_id: string; pdf_base64: string }[] = Array.isArray(body.boletas) ? body.boletas : [];
    if (!sede || !periodo || !boletas.length) return json({ error: 'Faltan sede, periodo o boletas' }, 400);
    if (boletas.length > MAX_POR_LLAMADA) return json({ error: `Máximo ${MAX_POR_LLAMADA} boletas por envío` }, 400);

    // 3) La quincena debe estar cerrada: los montos salen del cierre ---------
    const { data: cierre } = await admin.from('planilla_periodos').select('id,detalle')
      .eq('sede', sede).eq('periodo', periodo).maybeSingle();
    if (!cierre) return json({ error: 'La quincena no está cerrada. Ciérrela antes de enviar las boletas.' }, 400);
    const lineas: any[] = Array.isArray(cierre.detalle) ? cierre.detalle : [];

    const ids = boletas.map((b) => b.empleado_id);
    const { data: emps } = await admin.from('empleados').select('id,nombre,correo').in('id', ids);
    const correoDe = new Map((emps || []).map((e: any) => [e.id, (e.correo || '').trim()]));

    const transport = nodemailer.createTransport({
      host: 'smtp.gmail.com', port: 465, secure: true,
      auth: { user: GMAIL_USER, pass: GMAIL_PASS.replace(/\s+/g, '') },
    });

    // 4) Enviar uno por uno y registrar --------------------------------------
    const resultados: any[] = [];
    for (const b of boletas) {
      const l = lineas.find((x) => x.empleado_id === b.empleado_id);
      const correo = correoDe.get(b.empleado_id) || '';
      let estado = 'enviado', error: string | null = null;
      if (!l) { estado = 'error'; error = 'El colaborador no está en el cierre de esta quincena'; }
      else if (!correo || !correo.includes('@')) { estado = 'sin_correo'; error = 'La ficha de RRHH no tiene correo'; }
      else if (!b.pdf_base64) { estado = 'error'; error = 'No llegó el PDF'; }
      else {
        try {
          const nombreArchivo = `boleta_${periodo}_${String(l.nombre || 'colaborador').normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/\s+/g, '_')}.pdf`;
          await transport.sendMail({
            from: `"${FROM_NAME}" <${GMAIL_USER}>`,
            to: correo,
            subject: `Boleta de pago · ${etiqueta}`,
            html: cuerpoHtml(l, etiqueta, sede),
            attachments: [{ filename: nombreArchivo, content: b.pdf_base64, encoding: 'base64', contentType: 'application/pdf' }],
          });
        } catch (e) { estado = 'error'; error = (e as Error).message?.slice(0, 300) || 'Error al enviar'; }
      }
      resultados.push({ empleado_id: b.empleado_id, nombre: l?.nombre || '', correo, estado, error });
      await admin.from('planilla_boletas_envios').insert({
        sede, periodo, empleado_id: b.empleado_id, correo: correo || null, estado, error,
        neto: l ? Math.round(l.neto || 0) : null, enviado_por: caller.user.email || null,
      });
    }
    return json({ ok: true, resultados });
  } catch (e) {
    return json({ error: (e as Error).message || 'Error inesperado' }, 500);
  }
});
