/* ════════════════════════════════════════════════════════════════════════
   Chloe — asistente de ayuda, botón flotante en todas las pantallas.

   · Chat: responde con el Manual Operativo (Edge Function `asistente`). Si no
     sabe algo o el trámite es de Administración, crea un ticket (o agrega los
     datos nuevos a una consulta pendiente del mismo asunto).
   · Mis consultas: los tickets de quien está conectado, la respuesta de
     Administración y "Agregar detalle" mientras sigan pendientes.
   · Pendientes (solo admin, admin_sedes, admin_g): responder y cerrar tickets.
     "Enseñar al asistente" hace que use esa respuesta en las próximas dudas.
   · Conocimiento (solo Administración): lo que le enseñaron desde el chat
     ("Chloe, agregá a tu conocimiento que…"); se puede quitar si quedó viejo.

   Requiere sesion.js cargado antes (usa Sesion.token/url/key) y la tabla de
   asistente.sql. Se incluye con <script src="/asistente.js"></script>.
   Una página con sesión propia (movil.html) define antes window.AsistenteSesion =
   { token, url, key, renovar } y el panel usa esa en vez de Sesion.
   /movil?asistente=pend (desde una notificación push) abre el panel en esa pestaña.
   ════════════════════════════════════════════════════════════════════════ */
(function () {
  if (window.__asistente || !(window.AsistenteSesion || window.Sesion)) return;
  window.__asistente = true;
  function S() { return window.AsistenteSesion || window.Sesion; }

  var ADMIN = ['admin', 'admin_sedes', 'admin_g'];
  var TIPO = { duda: 'Duda', anular_venta: 'Anular venta', revisar_sinpe: 'Revisar SINPE',
               descuadre_caja: 'Descuadre de caja', error_app: 'Error de la app', otro: 'Otro' };
  var HKEY = 'asistenteChat', VISTO = 'asistenteVisto';
  var yo = { token: null, uid: null, rol: null }, tab = 'chat', enviando = false, abrirEn = null;
  var chat = leerChat();
  try {
    var qs = new URLSearchParams(location.search), q = qs.get('asistente');
    if (q === 'pend' || q === 'mis' || q === 'chat') {
      abrirEn = q; qs.delete('asistente');
      history.replaceState(null, '', location.pathname + (qs.toString() ? '?' + qs : '') + location.hash);
    }
  } catch (_) {}

  function leerChat() { try { return JSON.parse(sessionStorage.getItem(HKEY) || 'null') || { historial: [], burbujas: [] }; } catch (_) { return { historial: [], burbujas: [] }; } }
  function guardarChat() { try { sessionStorage.setItem(HKEY, JSON.stringify(chat)); } catch (_) {} }
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  // Texto del asistente: escapado, con **negritas** y saltos de línea
  function fmt(s) { return esc(s).replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>').replace(/\n/g, '<br>'); }
  function fecha(s) { try { return new Date(s).toLocaleString('es-CR', { day: '2-digit', month: 'short', hour: 'numeric', minute: '2-digit' }); } catch (_) { return ''; } }
  function uidDe(tok) { try { return JSON.parse(atob(tok.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))).sub; } catch (_) { return null; } }
  function esAdmin() { return ADMIN.indexOf(yo.rol) >= 0; }

  function api(path, opt) {
    opt = opt || {};
    var s = S();
    var h = { apikey: s.key(), Authorization: 'Bearer ' + s.token(), 'Content-Type': 'application/json' };
    if (opt.method === 'PATCH') h.Prefer = 'return=minimal';
    return fetch(s.url() + path, { method: opt.method || 'GET', headers: h, body: opt.body ? JSON.stringify(opt.body) : undefined })
      .then(function (r) {
        // Sesión propia vencida (app móvil): se renueva y se reintenta una vez
        if (r.status === 401 && !opt._re && window.AsistenteSesion && AsistenteSesion.renovar) {
          return Promise.resolve(AsistenteSesion.renovar()).then(function (ok) {
            return ok ? api(path, Object.assign({}, opt, { _re: true })) : leerResp(r);
          });
        }
        return leerResp(r);
      });
  }
  function leerResp(r) {
    return r.text().then(function (t) {
        var j = null; try { j = t ? JSON.parse(t) : null; } catch (_) {}
        if (!r.ok) { var e = new Error((j && (j.error || j.message)) || ('Error ' + r.status)); e.data = j; throw e; }
        return j;
      });
  }

  /* ── Estilos ── */
  var css = document.createElement('style');
  css.textContent =
    '#asis-btn{position:fixed;right:16px;bottom:calc(env(safe-area-inset-bottom) + 16px);z-index:9000;width:56px;height:56px;border-radius:50%;border:0;cursor:pointer;background:var(--brand,#0E9F8E);color:#fff;font-size:26px;box-shadow:0 8px 24px rgba(0,0,0,.25);display:none;align-items:center;justify-content:center}' +
    '#asis-btn.alto{bottom:calc(env(safe-area-inset-bottom) + 92px)}' +
    '#asis-btn .n{position:absolute;top:-2px;right:-2px;min-width:20px;height:20px;padding:0 5px;border-radius:10px;background:var(--red,#ff3b30);color:#fff;font:600 12px/20px -apple-system,system-ui,sans-serif;display:none}' +
    '#asis-p{position:fixed;right:16px;bottom:calc(env(safe-area-inset-bottom) + 84px);z-index:9001;width:min(400px,calc(100vw - 32px));height:min(600px,calc(100vh - 120px));background:var(--card,#fff);color:var(--label,#000);border-radius:18px;box-shadow:0 24px 64px rgba(0,0,0,.35);display:none;flex-direction:column;overflow:hidden;font:15px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}' +
    '#asis-p.alto{bottom:calc(env(safe-area-inset-bottom) + 160px);height:min(560px,calc(100vh - 190px))}' +
    '#asis-p header{display:flex;align-items:center;gap:6px;padding:10px 12px;border-bottom:.5px solid var(--sep,rgba(60,60,67,.29))}' +
    '#asis-p header b{flex:1;font-size:16px}' +
    '#asis-p .asis-tabs{display:flex;gap:4px;padding:8px 12px 0}' +
    '#asis-p .asis-tabs button,#asis-p .chip{border:0;border-radius:10px;padding:6px 10px;font-weight:600;font-size:13px;font-family:inherit;cursor:pointer;background:var(--fill,rgba(120,120,128,.12));color:var(--label,#000)}' +
    '#asis-p .asis-tabs button.on{background:var(--brand,#0E9F8E);color:#fff}' +
    '#asis-c{flex:1;overflow-y:auto;padding:12px;display:flex;flex-direction:column;gap:8px}' +
    '#asis-c .m{max-width:88%;padding:8px 12px;border-radius:14px;white-space:normal;word-wrap:break-word}' +
    '#asis-c .u{align-self:flex-end;background:var(--brand,#0E9F8E);color:#fff}' +
    '#asis-c .a{align-self:flex-start;background:var(--fill,rgba(120,120,128,.12))}' +
    '#asis-c .e{align-self:center;color:var(--red,#ff3b30);font-size:13px;text-align:center}' +
    '#asis-c .vacio{color:var(--sec,#666);font-size:14px;text-align:center;margin:auto 8px}' +
    '#asis-c .t{border:.5px solid var(--sep,rgba(60,60,67,.29));border-radius:12px;padding:10px;font-size:14px}' +
    '#asis-c .t small{color:var(--sec,#666);display:block}' +
    '#asis-c .t .r{margin-top:6px;padding:8px;border-radius:8px;background:var(--brand-tint,rgba(14,159,142,.14))}' +
    '#asis-c .ag{margin-top:6px;padding-left:8px;border-left:2px solid var(--sep,#ccc)}' +
    '#asis-c textarea{width:100%;box-sizing:border-box;margin-top:6px;min-height:60px;border-radius:8px;border:1px solid var(--sep,#ccc);padding:6px;font-size:14px;font-family:inherit;background:var(--card,#fff);color:var(--label,#000)}' +
    '#asis-f{display:flex;gap:6px;padding:10px 12px;border-top:.5px solid var(--sep,rgba(60,60,67,.29))}' +
    '#asis-f textarea{flex:1;resize:none;height:42px;max-height:120px;border-radius:12px;border:0;padding:10px 12px;font-size:16px;font-family:inherit;background:var(--fill,rgba(120,120,128,.12));color:var(--label,#000);outline:none}' +
    '#asis-f button{border:0;border-radius:12px;padding:0 14px;background:var(--brand,#0E9F8E);color:#fff;font-weight:600;font-size:15px;font-family:inherit;cursor:pointer}' +
    '#asis-f button:disabled{opacity:.5}';
  document.head.appendChild(css);

  /* ── Botón y panel ── */
  var btn = document.createElement('button');
  btn.id = 'asis-btn'; btn.type = 'button'; btn.title = 'Chloe · Ayuda'; btn.setAttribute('aria-label', 'Abrir ayuda de Chloe');
  btn.innerHTML = '💬<span class="n"></span>';
  var p = document.createElement('div');
  p.id = 'asis-p'; p.setAttribute('role', 'dialog'); p.setAttribute('aria-label', 'Chloe');
  p.innerHTML =
    '<header><b>Chloe</b><button class="chip" id="asis-nueva" type="button">Nueva</button><button class="chip" id="asis-x" type="button" aria-label="Cerrar">✕</button></header>' +
    '<div class="asis-tabs"><button data-t="chat" class="on" type="button">Chat</button><button data-t="mis" type="button">Mis consultas</button><button data-t="pend" type="button" style="display:none">Pendientes</button><button data-t="con" type="button" style="display:none">Conocimiento</button></div>' +
    '<div id="asis-c"></div>' +
    '<form id="asis-f"><textarea id="asis-i" rows="1" placeholder="Escríbale a Chloe…"></textarea><button type="submit" id="asis-s">Enviar</button></form>';

  function montar() {
    document.body.appendChild(btn); document.body.appendChild(p);
    // movil.html tiene una barra inferior: subir el botón para no taparla
    if (document.querySelector('.tabbar')) { btn.classList.add('alto'); p.classList.add('alto'); }
    btn.onclick = function () { abierto() ? cerrar() : abrir(); };
    $('asis-x').onclick = cerrar;
    $('asis-nueva').onclick = function () { chat = { historial: [], burbujas: [] }; guardarChat(); irA('chat'); };
    p.querySelectorAll('.asis-tabs button').forEach(function (b) { b.onclick = function () { irA(b.dataset.t); }; });
    $('asis-f').onsubmit = function (e) { e.preventDefault(); enviar(); };
    $('asis-i').onkeydown = function (e) { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); enviar(); } };
    vigilar(); setInterval(vigilar, 3000);
    setInterval(contar, 120000);
    // Notificación tocada con la app ya abierta (sw.js avisa por mensaje)
    if (navigator.serviceWorker) navigator.serviceWorker.addEventListener('message', function (e) {
      if (e.data && e.data.tipo === 'abrir-asistente') { abrirEn = e.data.tab || 'chat'; if (yo.rol) abrirPendiente(); }
    });
  }
  function abrirPendiente() {
    if (!abrirEn) return;
    tab = (abrirEn === 'pend' || abrirEn === 'con') && !esAdmin() ? 'mis' : abrirEn; abrirEn = null;
    abrir(); contar();
  }
  function $(id) { return document.getElementById(id); }
  function abierto() { return p.style.display === 'flex'; }
  function abrir() { p.style.display = 'flex'; irA(tab); }
  function cerrar() { p.style.display = 'none'; }

  // Mostrar el botón solo con sesión iniciada; detectar cambio de usuario
  function vigilar() {
    var t = S().token();
    if (!t) { btn.style.display = 'none'; cerrar(); yo = { token: null, uid: null, rol: null }; return; }
    btn.style.display = 'flex';
    var uid = uidDe(t);
    if (uid && uid !== yo.uid) {
      if (yo.uid) { chat = { historial: [], burbujas: [] }; guardarChat(); }
      yo = { token: t, uid: uid, rol: null };
      api('/rest/v1/user_roles?id=eq.' + uid + '&select=role').then(function (r) {
        yo.rol = r && r[0] && r[0].role;
        p.querySelector('[data-t=pend]').style.display = esAdmin() ? '' : 'none';
        p.querySelector('[data-t=con]').style.display = esAdmin() ? '' : 'none';
        contar(); abrirPendiente();
      }).catch(function () {});
    }
  }

  // Globito: admin → pendientes; resto → respuestas nuevas de Administración
  function contar() {
    if (!yo.uid) return;
    var q = esAdmin()
      ? '/rest/v1/asistente_tickets?estado=eq.pendiente&select=id'
      : '/rest/v1/asistente_tickets?user_id=eq.' + yo.uid + '&estado=eq.resuelto&resuelto_at=gt.' + encodeURIComponent(visto()) + '&select=id';
    api(q).then(function (r) {
      var n = (r || []).length, el = btn.querySelector('.n');
      el.textContent = n > 99 ? '99+' : n; el.style.display = n ? 'block' : 'none';
    }).catch(function () {});
  }
  function visto() { try { return localStorage.getItem(VISTO + yo.uid) || '1970-01-01T00:00:00Z'; } catch (_) { return '1970-01-01T00:00:00Z'; } }

  function irA(t) {
    tab = t;
    p.querySelectorAll('.asis-tabs button').forEach(function (b) { b.classList.toggle('on', b.dataset.t === t); });
    $('asis-f').style.display = t === 'chat' ? 'flex' : 'none';
    $('asis-nueva').style.display = t === 'chat' ? '' : 'none';
    if (t === 'chat') pintarChat();
    else if (t === 'mis') pintarMis();
    else if (t === 'con') pintarCon();
    else pintarPend();
  }

  /* ── Chat ── */
  function pintarChat() {
    var c = $('asis-c');
    c.innerHTML = chat.burbujas.length ? chat.burbujas.map(function (b) {
      return '<div class="m ' + b.r + '">' + (b.r === 'a' ? fmt(b.t) : esc(b.t)) + '</div>';
    }).join('') : '<div class="vacio">Hola, soy <b>Chloe</b>. Pregúnteme cómo hacer algo en la app o un procedimiento del manual: abrir o cerrar turno, SINPE, minita, mediciones, vacaciones…<br><br>Si no hay respuesta, o el trámite es de Administración, se crea una consulta y la respuesta aparece en <b>Mis consultas</b>. Si después tiene más datos, dígamelo y los agrego a esa misma consulta.' +
      (esAdmin() ? '<br><br>Administración: para enseñarme algo nuevo escriba, por ejemplo, <b>«Agregá a tu conocimiento que…»</b>. Lo verá en la pestaña <b>Conocimiento</b>.' : '') + '</div>';
    if (enviando) c.insertAdjacentHTML('beforeend', '<div class="m a">Escribiendo…</div>');
    c.scrollTop = c.scrollHeight;
  }

  function enviar() {
    var i = $('asis-i'), txt = i.value.trim();
    if (!txt || enviando) return;
    i.value = ''; enviando = true; $('asis-s').disabled = true;
    chat.burbujas.push({ r: 'u', t: txt }); guardarChat(); pintarChat();
    api('/functions/v1/asistente', { method: 'POST', body: { mensaje: txt, historial: chat.historial, pagina: location.pathname } })
      .then(function (d) {
        chat.historial = d.historial || [];
        chat.burbujas.push({ r: 'a', t: d.respuesta });
        if (d.tickets && d.tickets.length) contar();
      })
      .catch(function (e) {
        if (e.data && e.data.reiniciar) chat.historial = [];
        chat.burbujas.push({ r: 'e', t: e.message || 'No se pudo enviar.' });
      })
      .then(function () { enviando = false; $('asis-s').disabled = false; guardarChat(); if (tab === 'chat') pintarChat(); });
  }

  /* ── Mis consultas ── */
  // deAdmin: vista de Pendientes (muestra quién consultó y no el "⏳ Pendiente")
  function tarjeta(t, extra, deAdmin) {
    return '<div class="t"><small>#' + t.id + ' · ' + esc(TIPO[t.tipo] || t.tipo) + ' · ' + fecha(t.created_at) +
      (t.usuario && deAdmin ? ' · ' + esc(t.usuario) + (t.sede ? ' (' + esc(t.sede) + ')' : '') : '') + '</small>' +
      '<div><b>' + esc(t.resumen) + '</b></div>' +
      (t.detalle ? '<div style="margin-top:4px">' + esc(t.detalle) + '</div>' : '') +
      (t.agregados || []).map(function (a) { return '<div class="ag"><small>Agregado · ' + fecha(a.at) + '</small>' + esc(a.texto) + '</div>'; }).join('') +
      (t.respuesta ? '<div class="r"><small>Administración' + (t.resuelto_at ? ' · ' + fecha(t.resuelto_at) : '') + '</small>' + esc(t.respuesta) + '</div>'
                   : (t.estado === 'pendiente' && !deAdmin ? '<small style="margin-top:6px">⏳ Pendiente</small>' : '')) +
      (extra || '') + '</div>';
  }
  function pintarMis() {
    var c = $('asis-c'); c.innerHTML = '<div class="vacio">Cargando…</div>';
    api('/rest/v1/asistente_tickets?user_id=eq.' + yo.uid + '&order=created_at.desc&limit=30&select=*').then(function (r) {
      c.innerHTML = (r && r.length) ? r.map(function (t) {
        return tarjeta(t, t.estado !== 'pendiente' ? '' :
          '<div data-ag="' + t.id + '"><button class="chip" type="button" style="margin-top:8px">+ Agregar detalle</button></div>');
      }).join('') : '<div class="vacio">Todavía no tiene consultas.</div>';
      c.querySelectorAll('[data-ag] button').forEach(function (b) { b.onclick = function () { formAgregar(b.parentNode); }; });
      try { localStorage.setItem(VISTO + yo.uid, new Date().toISOString()); } catch (_) {}
      contar();
    }).catch(function (e) { c.innerHTML = '<div class="e">' + esc(e.message) + '</div>'; });
  }
  function formAgregar(box) {
    var id = box.dataset.ag;
    box.innerHTML = '<textarea id="asis-a' + id + '" maxlength="2000" placeholder="Lo que falta: fecha, monto, factura, referencia SINPE…"></textarea>' +
      '<button class="chip" type="button" style="margin-top:6px;background:var(--brand,#0E9F8E);color:#fff">Agregar a la consulta #' + id + '</button>';
    var ta = $('asis-a' + id), b = box.querySelector('button');
    ta.focus();
    b.onclick = function () {
      var txt = ta.value.trim(); if (!txt) { ta.focus(); return; }
      b.disabled = true; b.textContent = 'Guardando…';
      api('/functions/v1/asistente', { method: 'POST', body: { accion: 'agregar', ticket: Number(id), texto: txt } })
        .then(function () { pintarMis(); })
        .catch(function (e) { b.disabled = false; b.textContent = 'Agregar a la consulta #' + id; alert(e.message); });
    };
  }

  /* ── Pendientes (Administración) ── */
  function pintarPend() {
    var c = $('asis-c'); c.innerHTML = '<div class="vacio">Cargando…</div>';
    api('/rest/v1/asistente_tickets?estado=eq.pendiente&order=created_at.asc&limit=100&select=*').then(function (r) {
      if (!r || !r.length) { c.innerHTML = '<div class="vacio">No hay consultas pendientes. 🎉</div>'; return; }
      c.innerHTML = r.map(function (t) {
        return tarjeta(t,
          '<textarea id="asis-r' + t.id + '" placeholder="Respuesta para ' + esc(t.usuario || 'la persona') + '"></textarea>' +
          '<label style="display:flex;gap:6px;align-items:center;font-size:13px;margin-top:6px"><input type="checkbox" id="asis-e' + t.id + '"' + (t.tipo === 'duda' ? ' checked' : '') + '> Enseñarle a Chloe (la usará en próximas dudas)</label>' +
          '<button class="chip" type="button" data-id="' + t.id + '" style="margin-top:6px;background:var(--brand,#0E9F8E);color:#fff">Responder y cerrar</button>', true);
      }).join('');
      c.querySelectorAll('button[data-id]').forEach(function (b) { b.onclick = function () { resolver(b); }; });
    }).catch(function (e) { c.innerHTML = '<div class="e">' + esc(e.message) + '</div>'; });
  }
  function resolver(b) {
    var id = b.dataset.id, resp = $('asis-r' + id).value.trim();
    if (!resp) { $('asis-r' + id).focus(); return; }
    b.disabled = true; b.textContent = 'Guardando…';
    api('/rest/v1/asistente_tickets?id=eq.' + id, { method: 'PATCH', body: {
      estado: 'resuelto', respuesta: resp, en_asistente: $('asis-e' + id).checked,
      resuelto_por: yo.uid, resuelto_at: new Date().toISOString() } })
      .then(function () { pintarPend(); contar(); })
      .catch(function (e) { b.disabled = false; b.textContent = 'Responder y cerrar'; alert(e.message); });
  }

  /* ── Conocimiento (Administración) ── */
  function pintarCon() {
    var c = $('asis-c'); c.innerHTML = '<div class="vacio">Cargando…</div>';
    api('/rest/v1/asistente_conocimiento?activo=eq.true&order=created_at.desc&limit=200&select=*').then(function (r) {
      c.innerHTML = (r && r.length) ? r.map(function (n) {
        return '<div class="t"><small>#' + n.id + ' · ' + fecha(n.created_at) + (n.autor ? ' · ' + esc(n.autor) : '') + '</small>' +
          '<div><b>' + esc(n.tema) + '</b></div><div style="margin-top:4px;white-space:pre-wrap">' + esc(n.contenido) + '</div>' +
          '<button class="chip" type="button" data-q="' + n.id + '" style="margin-top:8px">Quitar</button></div>';
      }).join('') : '<div class="vacio">Chloe todavía no tiene conocimiento agregado.<br><br>En el Chat escríbale, por ejemplo: «Agregá a tu conocimiento que desde el 1 de noviembre la mensualidad en Pinares cuesta ₡25 000».</div>';
      c.querySelectorAll('button[data-q]').forEach(function (b) { b.onclick = function () { quitarCon(b); }; });
    }).catch(function (e) { c.innerHTML = '<div class="e">' + esc(e.message) + '</div>'; });
  }
  function quitarCon(b) {
    if (!confirm('¿Quitar la nota #' + b.dataset.q + '? Chloe deja de usarla desde la próxima consulta.')) return;
    b.disabled = true; b.textContent = 'Quitando…';
    api('/rest/v1/asistente_conocimiento?id=eq.' + b.dataset.q, { method: 'PATCH', body: {
      activo: false, quitado_por: yo.uid, quitado_at: new Date().toISOString() } })
      .then(pintarCon)
      .catch(function (e) { b.disabled = false; b.textContent = 'Quitar'; alert(e.message); });
  }

  if (document.body) montar(); else document.addEventListener('DOMContentLoaded', montar);
})();
