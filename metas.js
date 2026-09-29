/* ══════════════════════════════════════════════════════════════════════════
   metas.js — Meta mensual de cobro por sede
   Lo usan comparativa.html y sedes.html, así la meta, lo cobrado y lo que
   falta se calculan EXACTAMENTE igual en las dos páginas.

   Criterio de "cobrado": el mismo de Comparativa — pagos de membresía del
   informe de ventas (renov_data), sin clases sueltas ni productos sin
   clasificar. "Proyección": activos cuyo plan vence dentro del mes.

   Tabla: metas_sedes (sede, mes_orden 'YYYY-MM', monto). Ver metas_sedes.sql.
   Usa la función global supaFetch() de la página que lo incluye.
   Los estilos viven en /ui.css (sección "Metas").

     await Metas.cargar('2026-09')              → { '3 Ríos': 4200000, … }
     Metas.calcular({ snaps, mesOrden, corte }) → totales y detalle por sede
     Metas.htmlResumen(calc) / Metas.htmlSede(calc, sede)
     Metas.abrirEditor({ mesOrden, mesTxt, calc, onGuardado })
   ══════════════════════════════════════════════════════════════════════════ */
(function () {
  var SEDES = ['3 Ríos', 'Natación', 'Pinares', 'Sabanilla'];
  var cache = {};            // mesOrden → { sede: monto }
  var precios = null;        // sede → { planNormalizado: precio }
  var tablaFalta = false;    // true si metas_sedes todavía no existe

  var fmt = function (n) { return '₡' + Math.round(n).toLocaleString('es-CR'); };
  var norm = function (s) { return s ? String(s).toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/\s+/g, ' ').trim() : ''; };
  var esc = function (s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); };

  function parseDMY(str) {
    var m = String(str || '').match(/(\d{1,2})\/(\d{1,2})\/(\d{2,4})/);
    if (!m) return null;
    var y = parseInt(m[3], 10); if (y < 100) y += 2000;
    var d = new Date(y, parseInt(m[2], 10) - 1, parseInt(m[1], 10));
    return isNaN(d) ? null : d;
  }
  function limitesMes(mesOrden) {
    var p = mesOrden.split('-');
    var ini = new Date(+p[0], +p[1] - 1, 1);
    var fin = new Date(+p[0], +p[1], 0, 23, 59, 59);
    return { ini: ini, fin: fin };
  }
  function mesOrdenDe(d) { return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0'); }
  // 'YYYY-MM' o 'Septiembre de 2026' (snapshots viejos) → 'YYYY-MM'; null si no se entiende
  var MESES = { enero: 1, febrero: 2, marzo: 3, abril: 4, mayo: 5, junio: 6, julio: 7, agosto: 8, septiembre: 9, setiembre: 9, octubre: 10, noviembre: 11, diciembre: 12 };
  function normalizarMes(s) {
    s = String(s || '').trim();
    if (/^\d{4}-\d{2}$/.test(s)) return s;
    var m = norm(s).match(/([a-z]+)\s*(?:de)?\s*(\d{4})/);
    return m && MESES[m[1]] ? m[2] + '-' + String(MESES[m[1]]).padStart(2, '0') : null;
  }

  /* ── Precios de respaldo (plan_prices) para planes que vienen en ₡0 ── */
  async function cargarPrecios() {
    if (precios) return;
    precios = {};
    try {
      var rows = await supaFetch('/plan_prices?select=sede,plan,precio') || [];
      rows.forEach(function (r) { (precios[r.sede] = precios[r.sede] || {})[norm(r.plan)] = r.precio; });
    } catch (e) { console.warn('metas: no se pudieron cargar plan_prices:', e.message); }
  }
  function precioRespaldo(sede, plan) {
    var m = precios && precios[sede];
    if (!m || !plan) return 0;
    var k = norm(plan);
    if (m[k] != null) return m[k];
    for (var key in m) if (key.indexOf(k) >= 0 || k.indexOf(key) >= 0) return m[key];
    return 0;
  }

  /* ── Cálculos ── */
  function cobrado(snap, desde, hasta) {
    return (snap.renov_data || []).reduce(function (s, r) {
      if (r.EsClaseSuelta || r.EsSinClasificar) return s;
      var d = parseDMY(r.FechaStr);
      return d && d >= desde && d <= hasta ? s + (Number(r.Total) || 0) : s;
    }, 0);
  }
  function proyeccion(snap, sede, desde, hasta) {
    return (snap.users_data || []).reduce(function (s, u) {
      if (u.Activo !== 'Sí') return s;
      var d = parseDMY(u.Expira);
      if (!d || d < desde || d > hasta) return s;
      return s + (Number(u.ValorPlan) || precioRespaldo(sede, u.ÚltimoProducto));
    }, 0);
  }

  /* Metas guardadas de un mes. Devuelve {} si no hay; marca tablaFalta si la
     tabla todavía no se creó (para avisar que falta correr el SQL). */
  async function cargar(mesOrden, forzar) {
    if (!forzar && cache[mesOrden]) return cache[mesOrden];
    await cargarPrecios();
    var out = {};
    try {
      var rows = await supaFetch('/metas_sedes?mes_orden=eq.' + encodeURIComponent(mesOrden) + '&select=sede,monto,updated_by,updated_at') || [];
      rows.forEach(function (r) { out[r.sede] = Number(r.monto) || 0; });
      tablaFalta = false;
    } catch (e) {
      tablaFalta = /metas_sedes|does not exist|42P01|PGRST205/i.test(e.message || '');
      console.warn('metas: no se pudieron cargar:', e.message);
    }
    cache[mesOrden] = out;
    return out;
  }

  /* snaps: { sede: snapshot } del mes (con renov_data y users_data).
     corte: hasta qué fecha contar lo cobrado (por defecto, fin de mes). */
  function calcular(o) {
    var lim = limitesMes(o.mesOrden);
    var corte = o.corte && o.corte < lim.fin ? o.corte : lim.fin;
    var metas = cache[o.mesOrden] || {};
    var hoy = new Date(); hoy.setHours(0, 0, 0, 0);
    var esMesActual = mesOrdenDe(hoy) === o.mesOrden;
    var ultimoDia = lim.fin.getDate();
    // Días que quedan contando hoy (hoy todavía puede entrar plata)
    var diasRestantes = esMesActual ? ultimoDia - hoy.getDate() + 1 : 0;
    var porSede = {}, t = { meta: 0, cobrado: 0, proy: 0, metaDe: 0, sedesConMeta: 0 };
    SEDES.forEach(function (sede) {
      var snap = o.snaps[sede];
      var r = {
        meta: metas[sede] || 0,
        cobrado: snap ? cobrado(snap, lim.ini, corte) : 0,
        proy: snap ? proyeccion(snap, sede, lim.ini, lim.fin) : 0,
        conDatos: !!snap
      };
      r.falta = Math.max(0, r.meta - r.cobrado);
      r.pct = r.meta > 0 ? r.cobrado / r.meta * 100 : 0;
      porSede[sede] = r;
      t.proy += r.proy;
      if (r.meta > 0) { t.meta += r.meta; t.cobrado += r.cobrado; t.metaDe += r.proy; t.sedesConMeta++; }
    });
    t.falta = Math.max(0, t.meta - t.cobrado);
    t.pct = t.meta > 0 ? t.cobrado / t.meta * 100 : 0;
    return {
      mesOrden: o.mesOrden, mesTxt: o.mesTxt || o.mesOrden, porSede: porSede, total: t,
      esMesActual: esMesActual, diasRestantes: diasRestantes,
      // En el mes en curso, la etiqueta dice hasta hoy (no hay cobros futuros que contar)
      corteTxt: (esMesActual && corte > hoy ? new Date() : corte).toLocaleDateString('es-CR', { day: 'numeric', month: 'short' }),
      tablaFalta: tablaFalta
    };
  }

  // Barra en color de marca; verde cuando se cumple la meta (la leyenda dice "Cobrado")
  var tono = function (p) { return p >= 100 ? 'var(--green)' : 'var(--brand)'; };

  /* Barra de avance con una marca donde queda la proyección */
  function barra(cob, meta, proy) {
    var pct = meta > 0 ? Math.min(cob / meta * 100, 100) : 0;
    var pProy = meta > 0 && proy > 0 ? Math.min(proy / meta * 100, 100) : null;
    return '<div class="meta-bar"><i style="width:' + pct.toFixed(1) + '%;background:' + tono(cob / meta * 100) + '"></i>' +
      (pProy != null ? '<b style="left:' + pProy.toFixed(1) + '%" title="Proyección: ' + fmt(proy) + '"></b>' : '') + '</div>';
  }

  function htmlResumen(c) {
    var t = c.total;
    var boton = '<button class="btn-ghost" onclick="Metas._editar()">🎯 ' + (t.sedesConMeta ? 'Editar metas' : 'Definir metas') + '</button>';
    if (c.tablaFalta) {
      return '<div class="meta-card meta-vacia"><div><b>Falta crear la tabla de metas.</b>' +
        '<div class="hint">Corra <code>metas_sedes.sql</code> en Supabase y recargue la página.</div></div></div>';
    }
    if (!t.sedesConMeta) {
      return '<div class="meta-card meta-vacia"><div><b>Sin metas para ' + esc(c.mesTxt) + '.</b>' +
        '<div class="hint">La proyección del mes es ' + fmt(t.proy) + '. Defina una meta por sede para ver cuánto falta.</div></div>' + boton + '</div>';
    }
    var cumplida = t.cobrado >= t.meta;
    var sobreProy = t.meta - t.metaDe;
    var ritmo = '';
    if (!cumplida && c.esMesActual && c.diasRestantes > 0) {
      ritmo = '<div class="meta-ritmo">Quedan <b>' + c.diasRestantes + ' día' + (c.diasRestantes === 1 ? '' : 's') +
        '</b> · hay que cobrar <b>' + fmt(t.falta / c.diasRestantes) + ' por día</b> para llegar</div>';
    }
    var parcial = t.sedesConMeta < SEDES.length
      ? '<div class="hint">Solo suma las ' + t.sedesConMeta + ' sedes con meta definida.</div>' : '';
    return '<div class="meta-card">' +
      '<div class="meta-top">' +
        '<div class="meta-fig"><span class="l">Meta de ' + esc(c.mesTxt) + '</span><span class="v">' + fmt(t.meta) + '</span>' +
          '<span class="s">' + (sobreProy >= 0 ? fmt(sobreProy) + ' sobre la proyección' : fmt(-sobreProy) + ' bajo la proyección') +
          (t.metaDe > 0 ? ' (' + (sobreProy >= 0 ? '+' : '') + (sobreProy / t.metaDe * 100).toFixed(0) + '%)' : '') + '</span></div>' +
        '<div class="meta-fig"><span class="l">Cobrado al ' + c.corteTxt + '</span><span class="v t-green">' + fmt(t.cobrado) + '</span>' +
          '<span class="s">' + t.pct.toFixed(1) + '% de la meta</span></div>' +
        '<div class="meta-fig"><span class="l">' + (cumplida ? 'Meta cumplida' : 'Falta para la meta') + '</span>' +
          '<span class="v ' + (cumplida ? 't-green' : 't-red') + '">' + (cumplida ? '+' + fmt(t.cobrado - t.meta) : fmt(t.falta)) + '</span>' +
          '<span class="s">' + (cumplida ? 'por encima de la meta 🎉' : 'de ' + fmt(t.meta)) + '</span></div>' +
        '<div class="meta-act">' + boton + '</div>' +
      '</div>' +
      barra(t.cobrado, t.meta, t.metaDe) +
      '<div class="meta-leyenda"><span><i class="c"></i>Cobrado</span><span><i class="p"></i>Proyección</span></div>' +
      ritmo + parcial +
    '</div>';
  }

  /* Bloque pequeño para la tarjeta de cada sede */
  function htmlSede(c, sede) {
    var r = c.porSede[sede];
    if (!r || !(r.meta > 0) || c.tablaFalta) return '';
    var cumplida = r.cobrado >= r.meta;
    return '<div class="meta-sede">' +
      '<div class="meta-sede-top"><span>🎯 Meta ' + fmt(r.meta) + '</span>' +
      '<b class="' + (cumplida ? 't-green' : 't-red') + '">' + (cumplida ? '✓ cumplida' : 'faltan ' + fmt(r.falta)) + '</b></div>' +
      barra(r.cobrado, r.meta, r.proy) + '</div>';
  }

  /* ── Editor ── */
  var ultimo = null;   // { mesOrden, mesTxt, calc, onGuardado } del último render
  function recordar(o) { ultimo = o; }

  function asegurarModal() {
    var m = document.getElementById('metasModal');
    if (m) return m;
    m = document.createElement('div');
    m.id = 'metasModal';
    m.className = 'modal-back';
    m.innerHTML = '<div class="modal" role="dialog" aria-modal="true" aria-labelledby="metasTitulo" style="max-width:520px">' +
      '<div class="modal-head" id="metasTitulo">Metas</div>' +
      '<div class="modal-body" id="metasBody"></div>' +
      '<div class="modal-foot"><span class="form-msg" id="metasMsg"></span>' +
      '<button class="btn-ghost" onclick="Metas._cerrar()">Cancelar</button>' +
      '<button class="btn-primary" id="metasGuardar" onclick="Metas._guardar()">Guardar</button></div></div>';
    m.addEventListener('click', function (e) { if (e.target === m) cerrar(); });
    document.body.appendChild(m);
    return m;
  }
  function cerrar() { var m = document.getElementById('metasModal'); if (m) m.classList.remove('open'); }

  function abrirEditor(o) {
    if (o) recordar(o);
    if (!ultimo) return;
    var c = ultimo.calc;
    var m = asegurarModal();
    document.getElementById('metasTitulo').textContent = 'Metas de ' + ultimo.mesTxt;
    document.getElementById('metasMsg').textContent = '';
    document.getElementById('metasMsg').className = 'form-msg';
    document.getElementById('metasBody').innerHTML =
      '<div class="hint">Una meta por sede para el mes. Deje la casilla vacía para quitarla.</div>' +
      '<div class="f-inline">' +
        '<div class="f-field"><label for="metasPct">Sugerir: % sobre la proyección</label>' +
        '<input id="metasPct" type="number" min="0" step="1" value="10" inputmode="numeric"></div>' +
        '<button class="btn-ghost" type="button" onclick="Metas._sugerir()">Aplicar</button>' +
      '</div>' +
      SEDES.map(function (s, i) {
        var r = c.porSede[s];
        return '<div class="f-field"><label for="metaIn' + i + '">' + esc(s) + '</label>' +
          '<input id="metaIn' + i + '" data-sede="' + esc(s) + '" data-proy="' + Math.round(r.proy) + '" type="number" min="0" step="1000" inputmode="numeric" placeholder="Sin meta" value="' + (r.meta > 0 ? Math.round(r.meta) : '') + '">' +
          '<span class="hint">' + (r.conDatos ? 'Proyección del mes: ' + fmt(r.proy) : 'Sin datos cargados este mes') + '</span></div>';
      }).join('');
    m.classList.add('open');
    setTimeout(function () { var el = document.getElementById('metaIn0'); if (el) el.focus(); }, 50);
  }

  function sugerir() {
    var pct = Number(document.getElementById('metasPct').value) || 0;
    document.querySelectorAll('#metasBody input[data-sede]').forEach(function (inp) {
      var p = Number(inp.dataset.proy) || 0;
      if (p > 0) inp.value = Math.round(p * (1 + pct / 100) / 1000) * 1000;   // redondeado a miles
    });
  }

  async function guardar() {
    var btn = document.getElementById('metasGuardar');
    var msg = document.getElementById('metasMsg');
    var mes = ultimo.mesOrden;
    var actuales = cache[mes] || {};
    var upserts = [], borrar = [];
    document.querySelectorAll('#metasBody input[data-sede]').forEach(function (inp) {
      var sede = inp.dataset.sede, v = Number(inp.value);
      if (inp.value !== '' && v > 0) { if (v !== actuales[sede]) upserts.push({ sede: sede, mes_orden: mes, monto: v }); }
      else if (actuales[sede]) borrar.push(sede);
    });
    if (!upserts.length && !borrar.length) { cerrar(); return; }
    btn.disabled = true; msg.className = 'form-msg'; msg.textContent = 'Guardando…';
    try {
      if (upserts.length) {
        await supaFetch('/metas_sedes?on_conflict=sede,mes_orden', { method: 'POST', prefer: 'resolution=merge-duplicates,return=minimal', body: upserts });
      }
      for (var i = 0; i < borrar.length; i++) {
        await supaFetch('/metas_sedes?sede=eq.' + encodeURIComponent(borrar[i]) + '&mes_orden=eq.' + encodeURIComponent(mes), { method: 'DELETE' });
      }
      await cargar(mes, true);
      cerrar();
      if (ultimo.onGuardado) ultimo.onGuardado();
    } catch (e) {
      msg.className = 'form-msg err';
      msg.textContent = /row-level security|42501|permission/i.test(e.message) ? 'Su usuario no puede cambiar metas.' : 'No se pudo guardar: ' + e.message;
    } finally { btn.disabled = false; }
  }

  document.addEventListener('keydown', function (e) {
    var m = document.getElementById('metasModal');
    if (!m || !m.classList.contains('open')) return;
    if (e.key === 'Escape') cerrar();
    if (e.key === 'Enter' && e.target.tagName === 'INPUT' && e.target.dataset.sede) guardar();
  });

  window.Metas = {
    cargar: cargar, calcular: calcular, htmlResumen: htmlResumen, htmlSede: htmlSede,
    recordar: recordar, abrirEditor: abrirEditor, mesOrdenDe: mesOrdenDe, normalizarMes: normalizarMes,
    _editar: function () { abrirEditor(); }, _cerrar: cerrar, _guardar: guardar, _sugerir: sugerir
  };
})();
