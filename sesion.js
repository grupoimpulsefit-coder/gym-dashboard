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
    idleMin: function () { return cfg.idleMin; }
  };
})();
