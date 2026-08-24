// ════════════════════════════════════════════════════════════════════════
//  Edge Function: crear-usuario
//  Crea una cuenta de acceso (auth) y le asigna rol + sede en user_roles.
//  Solo un administrador autenticado (rol admin / admin_sedes) puede llamarla.
//  La service_role key vive en el servidor (secret por defecto de Supabase),
//  nunca en el HTML.
//
//  Deploy:
//    supabase login
//    supabase link --project-ref <PROJECT_REF>
//    supabase functions deploy crear-usuario
//  (SUPABASE_URL, SUPABASE_ANON_KEY y SUPABASE_SERVICE_ROLE_KEY ya vienen
//   inyectadas por defecto en las Edge Functions; no hay que configurarlas.)
// ════════════════════════════════════════════════════════════════════════
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const SEDES = ['3 Ríos', 'Natación', 'Pinares', 'Sabanilla'];
const ROLES = ['recepcion', 'admin_sucursal', 'colaborador', 'admin_sedes', 'admin', 'empleado'];
const ROLES_CON_SEDE = ['recepcion', 'admin_sucursal', 'empleado'];

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Método no permitido' }, 405);

  try {
    const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
    const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;

    // 1) Verificar que quien llama es un administrador -----------------------
    const token = (req.headers.get('Authorization') || '').replace('Bearer ', '').trim();
    if (!token) return json({ error: 'No autenticado' }, 401);

    const asCaller = createClient(SUPABASE_URL, ANON, {
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const { data: caller, error: cErr } = await asCaller.auth.getUser();
    if (cErr || !caller?.user) return json({ error: 'Sesión inválida' }, 401);

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE);
    const { data: rolRow } = await admin
      .from('user_roles').select('role').eq('id', caller.user.id).single();
    if (!rolRow || !['admin', 'admin_sedes'].includes(rolRow.role)) {
      return json({ error: 'Solo un administrador puede crear cuentas' }, 403);
    }

    // 2) Validar el payload -------------------------------------------------
    const body = await req.json().catch(() => ({}));
    const email = String(body.email || '').trim().toLowerCase();
    const password = String(body.password || '');
    const nombre = String(body.nombre || '').trim();
    const role = String(body.role || 'recepcion').trim();
    const sede = String(body.sede || '').trim() || null;

    if (!email || !password) return json({ error: 'Correo y contraseña son obligatorios' }, 400);
    if (password.length < 6) return json({ error: 'La contraseña debe tener al menos 6 caracteres' }, 400);
    if (!ROLES.includes(role)) return json({ error: 'Rol inválido' }, 400);
    if (ROLES_CON_SEDE.includes(role) && !SEDES.includes(sede || '')) {
      return json({ error: 'Debe indicar una sede válida para este rol' }, 400);
    }

    // 3) Crear el usuario (ya confirmado, sin correo de verificación) --------
    const { data: created, error: crErr } = await admin.auth.admin.createUser({
      email, password, email_confirm: true, user_metadata: { nombre },
    });
    if (crErr || !created?.user) {
      return json({ error: crErr?.message || 'No se pudo crear el usuario' }, 400);
    }
    const uid = created.user.id;

    // 4) Asignar rol + sede en user_roles -----------------------------------
    const { error: insErr } = await admin.from('user_roles').insert({
      id: uid,
      role,
      nombre: nombre || email,
      sede: ['recepcion', 'admin_sucursal'].includes(role) ? sede : null,
    });
    if (insErr) {
      // Rollback: borrar el usuario auth para no dejar cuentas huérfanas
      await admin.auth.admin.deleteUser(uid);
      return json({ error: 'No se pudo asignar el rol: ' + insErr.message }, 400);
    }

    // Para empleados (y admin de sucursal): ligar la ficha de empleado existente
    // (por correo) a esta cuenta, para que el portal de vacaciones lo encuentre.
    if (role === 'empleado' || role === 'admin_sucursal') {
      await admin.from('empleados').update({ user_id: uid }).eq('correo', email).is('user_id', null);
    }

    return json({ ok: true, id: uid, email, role, sede });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
