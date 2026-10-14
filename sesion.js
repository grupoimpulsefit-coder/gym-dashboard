/* ════════════════════════════════════════════════════════════════════════
   Sesión compartida — renovación silenciosa + cierre por inactividad.

   Problema que resuelve: el access_token de Supabase dura 1 hora. Los módulos
   guardaban solo ese token y descartaban el refresh_token, así que al cumplirse
   la hora la pantalla seguía viéndose con sesión iniciada pero toda petición
   fallaba con "JWT expired" (sesión colgada).

   Cómo funciona:
     · Renueva el token ~2 min antes de que expire, en silencio.
     · La sesión vive en localStorage y la comparten TODAS las pestañas del
       mismo navegador: así no se pisan los tokens entre sí (el refresh_token
       de Supabase rota, y dos pestañas renovando a la vez se sacarían una a
       la otra) y la actividad en cualquier pestaña cuenta para el inactivo.
     · Si pasan `idleMin` minutos sin actividad en ninguna pestaña, cierra
       sesión, borra los tokens y avisa al módulo para volver al login.
     · Cerrar sesión en una pestaña cierra las demás.

   Uso desde cada módulo:
     Sesion.init({ url:SUPA_URL, key:SUPA_KEY, idleMin:30,
                   onToken: t => { currentToken = t; },
                   onExpira: motivo => { ...volver al login... } });
     Sesion.set(data)        → tras un login con contraseña
     Sesion.adoptar(auth)    → al entrar por SSO (gymAuth)
     await Sesion.renovar()  → reintento ante un 401
     Sesion.paraHandoff()    → { refresh_token, exp } para pasar a otro módulo
     Sesion.cerrar()         → al cerrar sesión
   ════════════════════════════════════════════════════════════════════════ */
(function () {
  var KEY = 'gymSesion', LOCK = 'gymSesionLock';
  var cfg = { url: '', key: '', onToken: null, onExpira: null, idleMin: 30 };
  var tRenov = null, tIdle = null, ultimoPush = 0, iniciado = false;

  function leer() { try { return JSON.parse(localStorage.getItem(KEY) || 'null'); } catch (_) { return null; } }
  function escribir(s) { try { localStorage.setItem(KEY, JSON.stringify(s)); } catch (_) {} }
  function borrar() { try { localStorage.removeItem(KEY); } catch (_) {} }
  function estado() { return leer() || {}; }

  function guardar(d, conservarLast) {
    var prev = estado();
    var s = {
      access_token: d.access_token,
      refresh_token: d.refresh_token || prev.refresh_token || null,
      exp: Date.now() + ((Number(d.expires_in) || 3600) * 1000),
      last: (conservarLast && prev.last) ? prev.last : Date.now()
    };
    escribir(s);
    if (cfg.onToken) cfg.onToken(s.access_token);
    programar(s);
    arrancarIdle();   // toda sesión nueva reactiva el vigilante (tras un cierre quedaba apagado)
    revisarTemporal(s.access_token);
    return s;
  }

  function arrancarIdle() { clearInterval(tIdle); tIdle = setInterval(chequeoIdle, 30000); }

  function programar(s) {
    clearTimeout(tRenov);
    var ms = Math.max(10000, (s.exp || 0) - Date.now() - 120000);   // 2 min antes de expirar
    tRenov = setTimeout(tick, ms);
  }

  function tick() {
    var s = estado();
    if (!s.access_token) return;
    // Si otra pestaña ya renovó, basta con adoptar su token
    if ((s.exp || 0) - Date.now() > 150000) {
      if (cfg.onToken) cfg.onToken(s.access_token);
      programar(s);
      return;
    }
    renovar();
  }

  function renovar() {
    var s = estado();
    if (!s.refresh_token) { expirar('vencida'); return Promise.resolve(false); }

    // Candado simple entre pestañas: si otra está renovando, esperamos su resultado
    var ahora = Date.now(), lock = 0;
    try { lock = Number(localStorage.getItem(LOCK) || 0); } catch (_) {}
    if (ahora - lock < 6000) {
      return new Promise(function (res) { setTimeout(res, 1800); }).then(function () {
        var s2 = estado();
        if (s2.access_token && (s2.exp || 0) > Date.now() + 60000) {
          if (cfg.onToken) cfg.onToken(s2.access_token);
          programar(s2);
          return true;
        }
        return pedirToken(s2.refresh_token || s.refresh_token);
      });
    }
    try { localStorage.setItem(LOCK, String(ahora)); } catch (_) {}
    return pedirToken(s.refresh_token);
  }

  function pedirToken(refresh) {
    if (!refresh) { expirar('vencida'); return Promise.resolve(false); }
    return fetch(cfg.url + '/auth/v1/token?grant_type=refresh_token', {
      method: 'POST',
      headers: { 'apikey': cfg.key, 'Content-Type': 'application/json' },
      body: JSON.stringify({ refresh_token: refresh })
    }).then(function (r) { return r.json(); })
      .then(function (d) {
        if (!d || !d.access_token) throw new Error('no renovó');
        guardar(d, true);          // conserva la marca de actividad
        return true;
      })
      .catch(function () { expirar('vencida'); return false; });
  }

  function expirar(motivo) {
    detener();
    borrar();
    if (cfg.onExpira) { try { cfg.onExpira(motivo); } catch (_) {} }
  }

  function actividad() {
    var ahora = Date.now();
    if (ahora - ultimoPush < 5000) return;      // no escribir en cada mousemove
    ultimoPush = ahora;
    var s = estado();
    if (!s.access_token) return;
    s.last = ahora;
    escribir(s);
  }

  function chequeoIdle() {
    var s = estado();
    if (!s.access_token) return;
    if (Date.now() - (s.last || 0) > cfg.idleMin * 60000) expirar('inactividad');
  }

  function detener() { clearTimeout(tRenov); clearInterval(tIdle); tRenov = null; tIdle = null; }

  /* ── Cambio de contraseña ─────────────────────────────────────────────────
     Las cuentas nuevas nacen con user_metadata.debe_cambiar_clave = true (lo pone
     la Edge Function crear-usuario). El token lo trae, así que al iniciar sesión
     (o al entrar por SSO) se pide crear una contraseña propia antes de seguir.
     Sesion.cambiarClave() también sirve para cambiarla cuando la persona quiera. */
  function claims(tok) {
    try {
      var p = String(tok || '').split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
      return JSON.parse(decodeURIComponent(escape(atob(p))));
    } catch (_) { return {}; }
  }
  function debeCambiar(tok) { var m = claims(tok).user_metadata; return !!(m && m.debe_cambiar_clave === true); }
  function errClave(j) {
    var m = (j && (j.msg || j.error_description || j.message || j.error)) || '';
    if (/same|different/i.test(m)) return 'La nueva contraseña debe ser distinta a la actual.';
    if (/weak|short|characters|length/i.test(m)) return 'La contraseña es muy débil: use al menos 8 caracteres, con letras y números.';
    if (/reauth|nonce|recent/i.test(m)) return 'Por seguridad, cierre sesión, vuelva a entrar e intente de nuevo.';
    return m || 'No se pudo cambiar la contraseña.';
  }
  function cambiarClave(o) {
    o = o || {};
    if (document.getElementById('ses-clave')) return;
    var url = o.url || cfg.url, key = o.key || cfg.key;
    var c = claims(o.token || estado().access_token);
    var email = o.email || c.email || '';
    var forzado = !!o.forzado;
    var campo = function (id, lab, ph, ac) {
      return '<label style="display:block;font-size:12px;font-weight:600;color:var(--sec,#6e6e73);text-transform:uppercase;letter-spacing:.04em;margin:12px 0 6px">' + lab + '</label>' +
        '<input id="' + id + '" type="password" placeholder="' + ph + '" autocomplete="' + ac + '" style="width:100%;box-sizing:border-box;min-height:44px;padding:0 12px;border:1.5px solid transparent;border-radius:10px;background:var(--fill,rgba(120,120,128,.12));color:var(--label,#1d1d1f);font-size:16px;font-family:inherit;outline:none">';
    };
    var btn = 'min-height:44px;padding:0 18px;border:0;border-radius:12px;font-size:15px;font-weight:600;font-family:inherit;cursor:pointer;';
    var el = document.createElement('div');
    el.id = 'ses-clave';
    el.setAttribute('style', 'position:fixed;inset:0;z-index:99999;background:rgba(0,0,0,.5);display:flex;align-items:center;justify-content:center;padding:16px;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,sans-serif');
    el.innerHTML =
      '<form style="width:100%;max-width:400px;background:var(--card,#fff);color:var(--label,#1d1d1f);border-radius:18px;padding:22px;box-shadow:0 24px 64px rgba(0,0,0,.35)">' +
        '<div style="font-size:20px;font-weight:700;letter-spacing:-.02em">' + (forzado ? '🔑 Cree su contraseña' : '🔑 Cambiar contraseña') + '</div>' +
        '<div style="font-size:14px;color:var(--sec,#6e6e73);margin-top:6px;line-height:1.4">' + (forzado
          ? 'Está entrando con una contraseña temporal. Para seguir, elija una contraseña propia que solo usted conozca.'
          : 'Cuenta: ' + String(email).replace(/[<>&"]/g, '')) + '</div>' +
        campo('sesClaveAct', forzado ? 'Contraseña temporal' : 'Contraseña actual', '', 'current-password') +
        campo('sesClaveNva', 'Nueva contraseña', 'Mínimo 8 caracteres', 'new-password') +
        campo('sesClaveRep', 'Repita la nueva', '', 'new-password') +
        '<div id="sesClaveErr" style="color:var(--red,#ff3b30);font-size:14px;min-height:20px;margin-top:10px"></div>' +
        '<div style="display:flex;gap:10px;justify-content:flex-end;margin-top:6px;flex-wrap:wrap">' +
          '<button type="button" id="sesClaveNo" style="' + btn + 'background:var(--fill,rgba(120,120,128,.12));color:var(--label,#1d1d1f)">' + (forzado ? 'Cerrar sesión' : 'Cancelar') + '</button>' +
          '<button type="submit" id="sesClaveSi" style="' + btn + 'background:var(--brand,#0a84ff);color:#fff">Guardar</button>' +
        '</div>' +
      '</form>';
    document.body.appendChild(el);
    var $ = function (id) { return document.getElementById(id); };
    var cerrarModal = function () { el.remove(); };
    setTimeout(function () { var i = $('sesClaveAct'); if (i) i.focus(); }, 50);
    $('sesClaveNo').onclick = function () {
      cerrarModal();
      if (!forzado) return;
      if (o.onSalir) o.onSalir();
      else if (typeof window.doLogout === 'function') window.doLogout();
      else location.reload();
    };
    el.querySelector('form').onsubmit = function (ev) {
      ev.preventDefault();
      var act = $('sesClaveAct').value, nva = $('sesClaveNva').value, rep = $('sesClaveRep').value, err = $('sesClaveErr');
      if (!act || !nva) { err.textContent = 'Complete los campos.'; return; }
      if (nva.length < 8) { err.textContent = 'La nueva contraseña debe tener al menos 8 caracteres.'; return; }
      if (!/[a-zA-Z]/.test(nva) || !/\d/.test(nva)) { err.textContent = 'Use letras y números.'; return; }
      if (nva !== rep) { err.textContent = 'Las dos contraseñas nuevas no coinciden.'; return; }
      if (nva === act) { err.textContent = 'La nueva contraseña debe ser distinta a la actual.'; return; }
      if (/^impulse\d{4}$/i.test(nva)) { err.textContent = 'No use el formato de la contraseña temporal.'; return; }
      if (!email) { err.textContent = 'No se pudo identificar la cuenta. Cierre sesión y vuelva a entrar.'; return; }
      var b = $('sesClaveSi'); b.disabled = true; b.textContent = 'Guardando…'; err.textContent = '';
      var login = function (pwd) {
        return fetch(url + '/auth/v1/token?grant_type=password', { method: 'POST',
          headers: { 'apikey': key, 'Content-Type': 'application/json' },
          body: JSON.stringify({ email: email, password: pwd }) }).then(function (r) { return r.json(); });
      };
      // 1) Confirma la contraseña actual (y deja una sesión recién iniciada para poder cambiarla)
      login(act).then(function (d) {
        if (!d || !d.access_token) throw new Error(forzado ? 'La contraseña temporal no es correcta.' : 'La contraseña actual no es correcta.');
        // 2) Cambia la contraseña y quita la marca de contraseña temporal
        return fetch(url + '/auth/v1/user', { method: 'PUT',
          headers: { 'apikey': key, 'Authorization': 'Bearer ' + d.access_token, 'Content-Type': 'application/json' },
          body: JSON.stringify({ password: nva, data: { debe_cambiar_clave: false } }) })
          .then(function (r) { return r.json().catch(function () { return {}; }).then(function (j) { if (!r.ok) throw new Error(errClave(j)); }); });
      })
      // 3) Entra con la nueva: el token nuevo ya no trae la marca
      .then(function () { return login(nva); })
      .then(function (d2) {
        if (d2 && d2.access_token) { if (o.onListo) o.onListo(d2); else if (iniciado) guardar(d2, false); }
        cerrarModal();
        avisoOk();
      })
      .catch(function (e) { b.disabled = false; b.textContent = 'Guardar'; err.textContent = e.message; });
    };
  }
  function avisoOk() {
    var t = document.createElement('div');
    t.textContent = '✓ Contraseña actualizada';
    t.setAttribute('style', 'position:fixed;left:50%;bottom:28px;transform:translateX(-50%);z-index:99999;background:#1d1d1f;color:#fff;padding:12px 18px;border-radius:14px;font-size:15px;font-weight:600;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;box-shadow:0 10px 30px rgba(0,0,0,.25)');
    document.body.appendChild(t);
    setTimeout(function () { t.remove(); }, 2600);
  }
  // Tras cada sesión nueva (login, SSO o renovación): si la cuenta tiene contraseña temporal, pedir cambiarla
  function revisarTemporal(tok) {
    if (!debeCambiar(tok) || document.getElementById('ses-clave')) return;
    var go = function () { cambiarClave({ forzado: true }); };
    if (document.body) setTimeout(go, 0); else document.addEventListener('DOMContentLoaded', go);
  }

  window.Sesion = {
    init: function (c) {
      Object.assign(cfg, c || {});
      if (iniciado) return;
      iniciado = true;
      ['click', 'keydown', 'touchstart', 'scroll', 'mousemove'].forEach(function (ev) {
        document.addEventListener(ev, actividad, { passive: true });
      });
      arrancarIdle();
      // Otra pestaña renovó o cerró sesión
      window.addEventListener('storage', function (e) {
        if (e.key !== KEY) return;
        var s = leer();
        if (!s || !s.access_token) { detener(); if (cfg.onExpira) cfg.onExpira('cerrada'); }
        else { if (cfg.onToken) cfg.onToken(s.access_token); programar(s); }
      });
    },
    set: function (d) { return guardar(d, false); },
    adoptar: function (auth) {
      if (!auth || !auth.token) return null;
      var segs = auth.exp ? Math.round((auth.exp - Date.now()) / 1000) : 3600;
      return guardar({ access_token: auth.token, refresh_token: auth.refresh_token || null,
                       expires_in: Math.max(60, segs) }, false);
    },
    token: function () { return estado().access_token || null; },
    renovar: renovar,
    paraHandoff: function () { var s = estado(); return { refresh_token: s.refresh_token || null, exp: s.exp || 0 }; },
    cerrar: function () { detener(); borrar(); },
    idleMin: function () { return cfg.idleMin; },
    cambiarClave: cambiarClave,           // abre el cambio de contraseña ({ forzado, url, key, token, onListo, onSalir })
    debeCambiarClave: debeCambiar         // (token) → true si la cuenta tiene contraseña temporal
  };
})();
