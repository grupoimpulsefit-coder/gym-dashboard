/* ══════════════════════════════════════════════════════════════════════════
   catalogo.js — Qué es cada producto del informe "Ventas por Producto"
   Lo usan caja.html (pregunta), index.html y nat.html (solo consultan).

   Tabla catalogo_ventas (sede, producto_norm, producto, tipo). Ver
   catalogo_ventas.sql. tipo: 'plan' | 'clase' | 'producto'.
   La decisión guardada manda sobre la regla por nombre (isMembershipPlan /
   isClaseSuelta), que se mantiene como respaldo y como sugerencia.

     await Catalogo.cargar(sede)        → carga el catálogo de esa sede
     Catalogo.tipo(producto)            → 'plan' | 'clase' | 'producto' | null
     Catalogo.desconocidos(ventas, conocidos, sugerir) → [{producto, norm, ventas, total, sugerido}]
     await Catalogo.preguntar({ sede, items })        → abre la ventana; resuelve al guardar u omitir
   Usa la función global supaFetch() de la página.
   ══════════════════════════════════════════════════════════════════════════ */
(function () {
  var porSede = {};           // sede → { norm: { producto, tipo } }
  var sedeActual = null;
  var disponible = null;      // null sin consultar · false si la tabla aún no existe

  // minúsculas, sin tildes, sin la cantidad final "(3)", espacios simples
  function norm(s) {
    return String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '')
      .replace(/\s*\(\d+\)\s*$/, '').replace(/\s+/g, ' ').trim();
  }
  var esc = function (s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); };
  var fmt = function (n) { return '₡' + Math.round(n).toLocaleString('es-CR'); };

  async function cargar(sede) {
    sedeActual = sede;
    if (!sede) return {};
    try {
      var rows = await supaFetch('/catalogo_ventas?sede=eq.' + encodeURIComponent(sede) + '&select=producto_norm,producto,tipo') || [];
      var m = {};
      rows.forEach(function (r) { m[r.producto_norm] = { producto: r.producto, tipo: r.tipo }; });
      porSede[sede] = m;
      disponible = true;
    } catch (e) {
      porSede[sede] = {};
      disponible = false;
      console.warn('catalogo_ventas no disponible:', e.message);
    }
    return porSede[sede];
  }

  function tipo(producto) {
    var m = porSede[sedeActual];
    var r = m && m[norm(producto)];
    return r ? r.tipo : null;
  }

  /* ventas: [{Producto, Total}] · conocidos: Set de nombres normalizados ya
     registrados (plan_prices, inventario) · sugerir(producto) → tipo */
  function desconocidos(ventas, conocidos, sugerir) {
    var m = porSede[sedeActual] || {};
    var acc = {};
    ventas.forEach(function (v) {
      var k = norm(v.Producto);
      if (!k || m[k] || conocidos.has(k)) return;
      if (!acc[k]) acc[k] = { producto: String(v.Producto).replace(/\s*\(\d+\)\s*$/, '').trim(), norm: k, ventas: 0, total: 0, sugerido: sugerir(v.Producto) };
      acc[k].ventas++; acc[k].total += Number(v.Total) || 0;
    });
    return Object.keys(acc).map(function (k) { return acc[k]; })
      .sort(function (a, b) { return b.total - a.total; });
  }

  /* ── Ventana ── */
  var ETIQ = { plan: '🎫 Plan', clase: '🤸 Clase / Sesión', producto: '🥤 Producto' };
  var AYUDA = {
    plan: 'Membresía: cuenta como ingreso de planes.',
    clase: 'Clase suelta o sesión: va con membresías en el cierre.',
    producto: 'Minita o mercadería: va en otros/minita.'
  };

  function estilos() {
    if (document.getElementById('cv-estilos')) return;
    var st = document.createElement('style');
    st.id = 'cv-estilos';
    st.textContent =
      '.cv-back{display:none;position:fixed;inset:0;background:rgba(0,0,0,.45);z-index:10050;align-items:center;justify-content:center;padding:20px;overflow-y:auto}' +
      '.cv-back.open{display:flex}' +
      '.cv-card{background:var(--bg);border-radius:16px;width:100%;max-width:640px;box-shadow:0 24px 64px rgba(0,0,0,.35);overflow:hidden;margin:auto;display:flex;flex-direction:column;max-height:92vh}' +
      '.cv-head{background:var(--card);padding:16px 22px;border-bottom:.5px solid var(--sep)}' +
      '.cv-head b{display:block;font-size:17px;font-weight:600;color:var(--label)}' +
      '.cv-head span{display:block;font-size:13px;color:var(--sec);margin-top:3px}' +
      '.cv-body{padding:14px 22px;overflow-y:auto;display:flex;flex-direction:column;gap:10px}' +
      '.cv-item{background:var(--card);border-radius:12px;box-shadow:var(--shadow);padding:12px 14px;display:flex;flex-direction:column;gap:8px}' +
      '.cv-top{display:flex;justify-content:space-between;gap:10px;align-items:baseline;flex-wrap:wrap}' +
      '.cv-top b{font-size:15px;font-weight:600;color:var(--label)}' +
      '.cv-top span{font-size:12px;color:var(--sec);white-space:nowrap}' +
      '.cv-seg{display:grid;grid-template-columns:repeat(3,1fr);gap:2px;background:var(--fill);border-radius:10px;padding:2px}' +
      '.cv-seg button{border:0;background:none;border-radius:8px;min-height:34px;font:inherit;font-size:13px;font-weight:600;color:var(--label);cursor:pointer;padding:0 6px}' +
      '.cv-seg button.on{background:var(--card);box-shadow:0 1px 3px rgba(0,0,0,.14)}' +
      '@media (prefers-color-scheme:dark){.cv-seg button.on{background:#636366}}' +
      '.cv-ayuda{font-size:12px;color:var(--sec)}' +
      '.cv-ayuda i{font-style:normal;color:var(--brand-text);font-weight:600}' +
      '.cv-foot{background:var(--card);padding:12px 22px;border-top:.5px solid var(--sep);display:flex;gap:10px;justify-content:flex-end;align-items:center;flex-wrap:wrap}' +
      '.cv-msg{margin-right:auto;font-size:13px;color:var(--sec)}' +
      '.cv-msg.err{color:var(--red);font-weight:600}' +
      '.cv-btn{border:0;border-radius:10px;min-height:38px;padding:0 16px;font:inherit;font-size:14px;font-weight:600;cursor:pointer;white-space:nowrap}' +
      '.cv-btn.pri{background:var(--brand);color:#fff}' +
      '.cv-btn.sec{background:var(--fill);color:var(--brand-text)}' +
      '.cv-btn:disabled{opacity:.5;cursor:default}' +
      '@media (max-width:760px){.cv-back{padding:0;align-items:flex-end}.cv-card{max-width:none;border-radius:18px 18px 0 0;max-height:94dvh}' +
      '.cv-foot{padding-bottom:calc(env(safe-area-inset-bottom) + 12px)}.cv-foot .cv-btn{flex:1}.cv-msg{width:100%}}';
    document.head.appendChild(st);
  }

  var abierto = null;   // { sede, items, elegido:{norm:tipo}, resolver }

  function pintar() {
    var a = abierto;
    document.getElementById('cvLista').innerHTML = a.items.map(function (it, i) {
      var t = a.elegido[it.norm];
      return '<div class="cv-item">' +
        '<div class="cv-top"><b>' + esc(it.producto) + '</b><span>' + it.ventas + ' venta' + (it.ventas === 1 ? '' : 's') + ' · ' + fmt(it.total) + '</span></div>' +
        '<div class="cv-seg" role="radiogroup" aria-label="Tipo de ' + esc(it.producto) + '">' +
          ['plan', 'clase', 'producto'].map(function (k) {
            return '<button type="button" role="radio" aria-checked="' + (t === k) + '" class="' + (t === k ? 'on' : '') + '" onclick="Catalogo._elegir(' + i + ',\'' + k + '\')">' + ETIQ[k] + '</button>';
          }).join('') +
        '</div>' +
        '<div class="cv-ayuda">' + AYUDA[t] + (t === it.sugerido ? ' <i>· sugerido por el nombre</i>' : '') + '</div>' +
      '</div>';
    }).join('');
  }

  function preguntar(o) {
    estilos();
    var el = document.getElementById('cvModal');
    if (!el) {
      el = document.createElement('div');
      el.id = 'cvModal';
      el.className = 'cv-back';
      el.innerHTML = '<div class="cv-card" role="dialog" aria-modal="true" aria-labelledby="cvTitulo">' +
        '<div class="cv-head"><b id="cvTitulo"></b><span id="cvSub"></span></div>' +
        '<div class="cv-body" id="cvLista"></div>' +
        '<div class="cv-foot"><span class="cv-msg" id="cvMsg"></span>' +
        '<button class="cv-btn sec" id="cvOmitir" onclick="Catalogo._omitir()">Decidir después</button>' +
        '<button class="cv-btn pri" id="cvGuardar" onclick="Catalogo._guardar()">Guardar y continuar</button></div></div>';
      document.body.appendChild(el);
    }
    return new Promise(function (resolver) {
      var elegido = {};
      o.items.forEach(function (it) { elegido[it.norm] = it.sugerido; });
      abierto = { sede: o.sede, items: o.items, elegido: elegido, resolver: resolver };
      var n = o.items.length;
      document.getElementById('cvTitulo').textContent = n === 1 ? 'Producto nuevo en el informe' : n + ' productos nuevos en el informe';
      document.getElementById('cvSub').textContent = (n === 1 ? 'No está registrado' : 'No están registrados') +
        ' en ' + o.sede + '. Indique qué es cada uno: se guarda y no se vuelve a preguntar.';
      document.getElementById('cvMsg').textContent = '';
      document.getElementById('cvMsg').className = 'cv-msg';
      // Un guardado anterior los deja deshabilitados al cerrar: reactivarlos en cada apertura
      document.getElementById('cvGuardar').disabled = false;
      document.getElementById('cvOmitir').disabled = false;
      pintar();
      el.classList.add('open');
    });
  }

  function cerrar(guardado) {
    document.getElementById('cvModal').classList.remove('open');
    var r = abierto && abierto.resolver; abierto = null;
    if (r) r(guardado);
  }

  async function guardar() {
    var a = abierto; if (!a) return;
    var btn = document.getElementById('cvGuardar'), om = document.getElementById('cvOmitir'), msg = document.getElementById('cvMsg');
    btn.disabled = om.disabled = true;
    msg.className = 'cv-msg'; msg.textContent = 'Guardando…';
    var filas = a.items.map(function (it) { return { sede: a.sede, producto_norm: it.norm, producto: it.producto, tipo: a.elegido[it.norm] }; });
    try {
      await supaFetch('/catalogo_ventas?on_conflict=sede,producto_norm', { method: 'POST', prefer: 'resolution=merge-duplicates,return=minimal', body: filas });
      var m = porSede[a.sede] = porSede[a.sede] || {};
      filas.forEach(function (f) { m[f.producto_norm] = { producto: f.producto, tipo: f.tipo }; });
      cerrar(true);
    } catch (e) {
      msg.className = 'cv-msg err';
      msg.textContent = /row-level security|42501|permission/i.test(e.message)
        ? 'Su usuario no puede registrar productos en esta sede.' : 'No se pudo guardar: ' + e.message;
      btn.disabled = om.disabled = false;
    }
  }

  window.Catalogo = {
    norm: norm, cargar: cargar, tipo: tipo, desconocidos: desconocidos, preguntar: preguntar,
    disponible: function () { return disponible === true; },
    _elegir: function (i, k) { abierto.elegido[abierto.items[i].norm] = k; pintar(); },
    _guardar: guardar,
    _omitir: function () { cerrar(false); }
  };
})();
