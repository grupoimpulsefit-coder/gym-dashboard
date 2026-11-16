/* ══════════════════════════════════════════════════════════════════════════
   recibos_instructores.js — Pagos por clase CON RECIBO (sin factura), p. ej.
   instructores de CrossFit. Pestaña «🧾 Recibos» de gastos.html.
   Base: recibos_plantillas.sql (y pagos_instructores.sql).

   · Recepción registra las clases de cada instructor (a mano o desde la
     plantilla semanal) y se guardan como gasto de Clases grupales, origen
     'recibo'. El día de pago lo pone la base con la HORA DE REGISTRO
     (corte miércoles y viernes 10:00 a. m.); fines de semana, caja.
   · Plantilla: las clases fijas de cada instructor por día de la semana.
     «Registrar desde la plantilla» arma las clases de un rango de fechas y
     salta las que ya se registraron, para no pagarlas dos veces.
   · Recibo en PDF para que el instructor lo firme (no hay factura).
   ══════════════════════════════════════════════════════════════════════════ */

let rcF = null;            // recibo que se está llenando a mano
let rcPlantilla = [];      // [{ id?, instructor_id, tarifa_id, dias:[7] }]
let rcPlantillaCambios = false;
let rcPrevia = null;       // clases propuestas desde la plantilla
let rcRegistradas = new Set();   // instructor|fecha|tipo ya registrados (para no duplicar)
let rcAviso = null;
const RC_DIAS = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
const rcNum = v => { const n = Number(String(v ?? '').replace(',', '.')); return isFinite(n) && n > 0 ? n : 0; };
const rcFinde = f => f && [0, 6].includes(parseFecha(f).getDay());
const rcTarifa = id => piTarifas.find(t => t.id === id) || null;
const rcClave = (inst, fecha, tipo) => `${inst}|${fecha}|${piNorm(tipo)}`;

function rcNuevo() {
  const hoy = piYMD(piAhoraCR());
  return { instructor_id: '', metodo: '', clases: [{ fecha: hoy, tarifaId: piTarifas[0]?.id || '', cantidad: 1 }], caja: rcFinde(hoy), cajaTocado: false, nota: '' };
}

// Rango por defecto para la plantilla: desde el lunes de esta semana hasta hoy
function rcRangoInicial() {
  const hoy = piAhoraCR();
  return { desde: piYMD(piLunes(hoy)), hasta: piYMD(hoy) };
}
let rcRango = null;

async function rcCargar() {
  const v = document.getElementById('vista_recibos');
  v.innerHTML = '<div class="loading" style="display:block;"><div class="spinner"></div><div>Cargando…</div></div>';
  try {
    if (!piTarifas.length) await piCargarCatalogos();
    rcPlantilla = ((await supaFetch(`/plantillas_pago?sede=eq.${encodeURIComponent(currentSede)}&tipo=eq.recibo&select=*`)) || [])
      .map(p => ({ ...p, dias: Array.isArray(p.dias) ? p.dias.map(Number) : [0, 0, 0, 0, 0, 0, 0] }));
    rcPlantilla.sort((a, b) => (phInst(a.instructor_id)?.nombre || '').localeCompare(phInst(b.instructor_id)?.nombre || '', 'es'));
    rcPlantillaCambios = false;
  } catch (e) {
    v.innerHTML = `<div class="empty-state" style="display:block;">⚠️ No se pudo cargar: ${esc(e.message)}`
      + (/plantillas_pago|relation|schema/i.test(e.message) ? '<br>¿Ya se corrió recibos_plantillas.sql en Supabase?' : '') + '</div>';
    return;
  }
  if (!rcF) rcF = rcNuevo();
  if (!rcRango) rcRango = rcRangoInicial();
  rcPrevia = null;
  rcRender();
}

// Clases ya registradas con recibo (para avisar o saltar duplicados)
async function rcCargarRegistradas(desde) {
  const rows = await supaFetchTodo(`/gastos?origen=eq.recibo&sede=eq.${encodeURIComponent(currentSede)}`
    + `&fecha_clase=gte.${piYMD(piSumarDias(parseFecha(desde), -7))}&select=id,instructor_id,detalle_clases&order=id.asc`);
  rcRegistradas = new Set();
  rows.forEach(g => (Array.isArray(g.detalle_clases) ? g.detalle_clases : []).forEach(c => rcRegistradas.add(rcClave(g.instructor_id, c.fecha, c.tipo))));
}

function rcRender() {
  const v = document.getElementById('vista_recibos');
  const aviso = rcAviso; rcAviso = null;
  v.innerHTML = `
    <div class="section"><div class="section-title">🧾 Pagos con recibo <span class="section-note">— ${esc(currentSede)} · instructores que cobran por clase y no dan factura</span></div></div>
    ${aviso ? `<div class="section" style="padding-top:0;"><div class="form-msg ${aviso.tipo}" style="font-size:15px;">${aviso.html}</div></div>` : ''}
    <div class="section" style="padding-top:0;"><div class="hint">Se paga igual que las facturas, según la hora en que se registra: antes del miércoles 10:00 a. m. → miércoles; antes del viernes 10:00 a. m. → viernes. Clases de sábado y domingo → caja.</div></div>
    <div class="form-card" id="rcManual"></div>
    <div class="form-card" id="rcDesdePlantilla"></div>
    <div class="form-card" id="rcPlantillaCard"></div>`;
  rcRenderManual();
  rcRenderDesdePlantilla();
  rcRenderPlantilla();
}

// ── 1) Registrar un recibo a mano ──
function rcRenderManual() {
  const el = document.getElementById('rcManual'); if (!el) return;
  const f = rcF, inst = phInst(f.instructor_id);
  const met = inst ? metodosDe(inst) : [];
  if (inst && !met.some(m => m.value === f.metodo)) f.metodo = met[0]?.value || '';
  const opcTipo = sel => '<option value="">— Tipo —</option>' + piTarifas.map(t => `<option value="${t.id}"${t.id === sel ? ' selected' : ''}>${esc(t.tipo)} · ${fmtCRC(t.monto)}</option>`).join('');
  el.innerHTML = `
    <div class="section-title" style="margin-bottom:12px;">Registrar un recibo</div>
    <div class="form-grid">
      <div class="f-field wide"><label for="rcInst">Instructor <span class="req">*</span></label>
        <div class="f-inline">
          <div class="f-field" style="gap:0;"><select id="rcInst" onchange="rcF.instructor_id=this.value; rcRenderManual();">
            <option value="">— Seleccione —</option>${instructores.map(i => `<option value="${i.id}"${i.id === f.instructor_id ? ' selected' : ''}>${esc(i.nombre)}</option>`).join('')}
          </select></div>
          <button class="btn-ghost" type="button" onclick="openInstructorModal()" title="Persona nueva">＋</button>
        </div></div>
      <div class="f-field"><label for="rcMetodo">Se le paga a</label>
        ${!inst ? '<div class="pay-box">Elija el instructor.</div>'
          : met.length ? `<select id="rcMetodo" onchange="rcF.metodo=this.value;">${met.map(m => `<option value="${m.value}"${m.value === f.metodo ? ' selected' : ''}>${esc(m.banco)} · ${esc(m.cuenta)}</option>`).join('')}</select>`
          : '<div class="pay-box">Sin cuenta ni SINPE en el directorio: solo se puede pagar de caja.</div>'}</div>
    </div>
    <div class="g-wrap" style="margin:14px 0 0;"><table class="g-table">
      <thead><tr><th>Fecha de la clase</th><th>Tipo de clase</th><th class="num">Cantidad</th><th class="num">Subtotal</th><th></th></tr></thead>
      <tbody>${f.clases.map((c, i) => `<tr>
        <td><input type="date" value="${esc(c.fecha)}" aria-label="Fecha de la clase" style="width:150px;text-align:left;" onchange="rcCambiar(${i},'fecha',this.value)"></td>
        <td><select class="ui" aria-label="Tipo de clase" onchange="rcCambiar(${i},'tarifaId',this.value)">${opcTipo(c.tarifaId)}</select></td>
        <td class="num"><input type="number" min="1" step="1" value="${esc(c.cantidad)}" aria-label="Cantidad" style="width:70px;" oninput="rcCambiar(${i},'cantidad',this.value)"></td>
        <td class="num" id="rcSub${i}"></td>
        <td class="num">${f.clases.length > 1 ? `<button class="btn-del" aria-label="Quitar fila" onclick="rcF.clases.splice(${i},1); rcRenderManual();">✕</button>` : ''}</td>
      </tr>`).join('')}</tbody>
    </table></div>
    <button class="btn-ghost" style="margin-top:8px;" onclick="rcAgregarClase()">＋ Agregar otra clase</button>
    <div class="form-grid" style="margin-top:12px;">
      <div class="f-field full"><label for="rcNota">Nota (opcional)</label><input id="rcNota" value="${esc(f.nota)}" placeholder="Ej. reemplazó a otro instructor" oninput="rcF.nota=this.value"></div>
    </div>
    <label style="display:flex;gap:10px;align-items:flex-start;margin-top:12px;padding:12px 14px;border-radius:10px;background:var(--fill);cursor:pointer;font-size:14px;">
      <input type="checkbox" id="rcCaja" ${f.caja ? 'checked' : ''} onchange="rcF.caja=this.checked; rcF.cajaTocado=true; rcActualizar();" style="width:20px;height:20px;margin:0;flex:none;">
      <span><b>Clase de fin de semana: se paga de caja</b><br><span class="hint">Igual entra a Gastos, pero no aparece en el pago del miércoles ni del viernes.</span></span>
    </label>
    <div class="form-actions" style="padding:12px 0 0;">
      <div class="form-msg" id="rcMsg"></div>
      <span id="rcTotal" style="font-weight:700;font-size:16px;"></span>
      <button class="btn-primary" id="rcGuardar" onclick="rcGuardarManual()">💾 Guardar recibo</button>
    </div>`;
  rcActualizar();
}
function rcCambiar(i, campo, valor) {
  rcF.clases[i][campo] = campo === 'cantidad' ? valor : valor;
  if (campo === 'fecha' && !rcF.cajaTocado) { rcF.caja = rcF.clases.every(c => rcFinde(c.fecha)); const cb = document.getElementById('rcCaja'); if (cb) cb.checked = rcF.caja; }
  rcActualizar();
}
function rcAgregarClase() {
  const u = rcF.clases[rcF.clases.length - 1];
  rcF.clases.push({ fecha: u ? u.fecha : piYMD(piAhoraCR()), tarifaId: u ? u.tarifaId : '', cantidad: 1 });
  rcRenderManual();
}
function rcFilas(clases) {
  return clases.map(c => { const t = rcTarifa(c.tarifaId); const cantidad = Math.round(rcNum(c.cantidad));
    return { fecha: c.fecha, tipo: t ? t.tipo : '', cantidad, tarifa: t ? Number(t.monto) : 0, subtotal: t ? cantidad * Number(t.monto) : 0 }; });
}
function rcActualizar() {
  const filas = rcFilas(rcF.clases), total = filas.reduce((s, x) => s + x.subtotal, 0);
  filas.forEach((x, i) => { const td = document.getElementById('rcSub' + i); if (td) td.textContent = x.tarifa ? fmtCRC(x.subtotal) : '—'; });
  const t = document.getElementById('rcTotal'); if (t) t.textContent = 'Total ' + fmtCRC(total);
  const m = document.getElementById('rcMsg');
  if (m) { const d = piDiaPagoEstimado(); m.className = 'form-msg'; m.textContent = rcF.caja ? 'Se paga de caja.' : (d ? `Si se guarda ahora, se paga el ${piFechaLarga(d)}.` : ''); }
}

// Guarda un recibo como gasto (origen 'recibo'); devuelve el gasto creado
async function rcGuardarRecibo(inst, metodo, filas, caja, nota) {
  const fecha = filas.map(r => r.fecha).sort()[0], d = parseFecha(fecha);
  const total = filas.reduce((s, x) => s + x.subtotal, 0);
  const m = caja ? null : metodosDe(inst).find(x => x.value === metodo);
  const r = await supaFetch('/gastos', { method: 'POST', prefer: 'return=representation', body: {
    sede: currentSede, categoria: 'clases_grupales', fecha_clase: fecha, mes: mesEtiqueta(d), mes_orden: mesOrden(d),
    emisor: inst.nombre, instructor_id: inst.id, documento_cobro: 'Recibo', numero_factura: null, monto: total,
    metodo_pago: caja ? 'caja' : (m ? m.value : null), banco_pago: caja ? 'Pago de caja' : (m ? m.banco : null), cuenta_pago: caja ? null : (m ? m.cuenta : null),
    created_by: currentEmail || null, origen: 'recibo', emisor_cedula: inst.cedula || null,
    detalle_clases: filas, monto_esperado: total, nota_diferencia: (nota || '').trim() || null, pago_tipo: caja ? 'caja' : 'transferencia',
  } });
  return Array.isArray(r) ? r[0] : r;
}

async function rcGuardarManual() {
  const f = rcF, msg = document.getElementById('rcMsg'), inst = phInst(f.instructor_id);
  const err = t => { msg.className = 'form-msg err'; msg.textContent = t; };
  if (!inst) return err('Elija el instructor.');
  const filas = rcFilas(f.clases);
  if (!filas.length || filas.some(x => !x.fecha || !x.tarifa || x.cantidad < 1)) return err('Complete la fecha, el tipo y la cantidad de cada clase.');
  if (!f.caja && !metodosDe(inst).length) return err('El instructor no tiene cuenta ni SINPE: márquelo como pago de caja o agregue su cuenta.');
  // Clases que ya se registraron (evita pagarlas dos veces)
  try { await rcCargarRegistradas(filas.map(x => x.fecha).sort()[0]); } catch (_) {}
  const repetidas = filas.filter(x => rcRegistradas.has(rcClave(inst.id, x.fecha, x.tipo)));
  if (repetidas.length && !confirm(`Ojo: ${inst.nombre} ya tiene registrado ${repetidas.map(x => `${x.tipo} del ${piFechaCorta(x.fecha)}`).join(', ')}.\n¿Registrar de todas formas?`)) return;
  const btn = document.getElementById('rcGuardar'); btn.disabled = true; btn.textContent = 'Guardando…';
  try {
    const g = await rcGuardarRecibo(inst, f.metodo, filas, f.caja, f.nota);
    rcF = rcNuevo();
    window._rcUltimos = [g];
    rcAviso = { tipo: 'ok', html: `✅ Recibo de ${esc(inst.nombre)} por ${fmtCRC(g.monto)} guardado. ${g.pago_tipo === 'caja' ? 'Se paga de caja.' : g.dia_pago ? 'Se paga el ' + esc(piFechaLarga(parseFecha(g.dia_pago))) + '.' : ''}
      <button class="btn-ghost" style="margin-left:8px;" onclick="rcReciboPDF(window._rcUltimos)">📄 Imprimir recibo</button>` };
    rcRender(); piRecargarGastos();
  } catch (e) {
    btn.disabled = false; btn.textContent = '💾 Guardar recibo';
    err(/origen|pago_tipo|column/i.test(e.message) ? 'Falta correr recibos_plantillas.sql en Supabase.' : 'No se pudo guardar: ' + mensajeErr(e));
  }
}
function mensajeErr(e) { try { return JSON.parse(e.message).message || e.message; } catch (_) { return e.message; } }

// ── 2) Registrar desde la plantilla ──
function rcRenderDesdePlantilla() {
  const el = document.getElementById('rcDesdePlantilla'); if (!el) return;
  const p = rcPrevia;
  const sel = p ? p.filter(x => x.ok && !x.ya) : [];
  const total = sel.reduce((s, x) => s + rcNum(x.cantidad) * x.tarifa, 0);
  el.innerHTML = `
    <div class="section-title" style="margin-bottom:4px;">📋 Registrar desde la plantilla</div>
    <div class="hint" style="margin-bottom:12px;">Arma las clases fijas de la plantilla entre dos fechas. Las que ya se registraron aparecen marcadas y no se vuelven a cargar. Ajuste las cantidades si algo cambió.</div>
    ${rcPlantilla.length ? `
    <div style="display:flex;flex-wrap:wrap;gap:10px;align-items:flex-end;">
      <div class="f-field"><label for="rcDesde">Desde</label><input type="date" id="rcDesde" value="${esc(rcRango.desde)}" onchange="rcRango.desde=this.value"></div>
      <div class="f-field"><label for="rcHasta">Hasta</label><input type="date" id="rcHasta" value="${esc(rcRango.hasta)}" onchange="rcRango.hasta=this.value"></div>
      <button class="btn-ghost" onclick="rcArmarPrevia()">Ver clases</button>
    </div>
    ${p ? (p.length ? `
    <div class="g-wrap" style="margin:14px 0 0;"><table class="g-table">
      <thead><tr><th></th><th>Instructor</th><th>Día</th><th>Tipo</th><th class="num">Cantidad</th><th class="num">Subtotal</th></tr></thead>
      <tbody>${p.map((x, i) => `<tr${x.ya ? ' style="opacity:.55;"' : ''}>
        <td><input type="checkbox" aria-label="Incluir" ${x.ok && !x.ya ? 'checked' : ''} ${x.ya ? 'disabled' : ''} onchange="rcPrevia[${i}].ok=this.checked; rcRenderDesdePlantilla();" style="width:20px;height:20px;"></td>
        <td>${esc(phInst(x.instructor_id)?.nombre || '—')}</td>
        <td>${esc(parseFecha(x.fecha).toLocaleDateString('es-CR', { weekday: 'short', day: 'numeric', month: 'short' }))}${rcFinde(x.fecha) ? ' <span class="pill">caja</span>' : ''}</td>
        <td>${esc(x.tipo)}</td>
        <td class="num">${x.ya ? '<span class="pill ok">Ya registrada</span>' : `<input type="number" min="0" step="1" value="${esc(x.cantidad)}" aria-label="Cantidad" style="width:64px;" onchange="rcPrevia[${i}].cantidad=this.value; rcRenderDesdePlantilla();">`}</td>
        <td class="num">${x.ya ? '' : fmtCRC(rcNum(x.cantidad) * x.tarifa)}</td>
      </tr>`).join('')}</tbody>
    </table></div>
    <div class="form-actions" style="padding:12px 0 0;">
      <div class="form-msg" id="rcPMsg">${sel.length ? `${new Set(sel.map(x => x.instructor_id)).size} instructor(es) · ${sel.length} día(s)` : 'Nada seleccionado.'}</div>
      <span style="font-weight:700;font-size:16px;">Total ${fmtCRC(total)}</span>
      <button class="btn-primary" id="rcPBtn" ${sel.length ? '' : 'disabled'} onclick="rcRegistrarPrevia()">💾 Registrar recibos</button>
    </div>` : '<div class="pay-box" style="margin-top:12px;">La plantilla no tiene clases en esas fechas.</div>') : ''}`
    : '<div class="pay-box">Todavía no hay plantilla. Ármela abajo, en «Plantilla semanal».</div>'}`;
}

async function rcArmarPrevia() {
  const { desde, hasta } = rcRango;
  if (!desde || !hasta || hasta < desde) { alert('Revise las fechas: «Hasta» debe ser igual o posterior a «Desde».'); return; }
  const dias = Math.round((parseFecha(hasta) - parseFecha(desde)) / 864e5);
  if (dias > 31) { alert('El rango puede ser de hasta 31 días.'); return; }
  try { await rcCargarRegistradas(desde); } catch (e) { alert('No se pudo revisar lo ya registrado: ' + e.message); return; }
  const out = [];
  for (let k = 0; k <= dias; k++) {
    const d = piSumarDias(parseFecha(desde), k), f = piYMD(d), idx = (d.getDay() + 6) % 7;
    rcPlantilla.forEach(p => {
      const n = rcNum(p.dias.at(idx)), t = rcTarifa(p.tarifa_id);
      if (!n || !t) return;
      out.push({ instructor_id: p.instructor_id, fecha: f, tarifaId: t.id, tipo: t.tipo, tarifa: Number(t.monto), cantidad: n,
        ya: rcRegistradas.has(rcClave(p.instructor_id, f, t.tipo)), ok: true });
    });
  }
  out.sort((a, b) => (phInst(a.instructor_id)?.nombre || '').localeCompare(phInst(b.instructor_id)?.nombre || '', 'es') || a.fecha.localeCompare(b.fecha));
  rcPrevia = out;
  rcRenderDesdePlantilla();
}

async function rcRegistrarPrevia() {
  const sel = (rcPrevia || []).filter(x => x.ok && !x.ya && rcNum(x.cantidad) >= 1);
  if (!sel.length) return;
  // Un recibo por instructor; las clases de fin de semana van aparte (caja)
  const grupos = new Map();
  sel.forEach(x => { const k = x.instructor_id + '|' + (rcFinde(x.fecha) ? 'caja' : 'tr'); if (!grupos.has(k)) grupos.set(k, []); grupos.get(k).push(x); });
  const sinCuenta = [...new Set([...grupos.keys()].filter(k => k.endsWith('|tr')).map(k => k.split('|')[0]))].filter(id => !metodosDe(phInst(id) || {}).length);
  if (sinCuenta.length) { alert(`No tienen cuenta ni SINPE: ${sinCuenta.map(id => phInst(id)?.nombre).join(', ')}. Agregue su cuenta o regístrelos a mano como pago de caja.`); return; }
  if (!confirm(`¿Registrar ${grupos.size} recibo(s)?`)) return;
  const btn = document.getElementById('rcPBtn'); btn.disabled = true; btn.textContent = 'Registrando…';
  const hechos = [], fallas = [];
  for (const [k, xs] of grupos) {
    const [instId, modo] = k.split('|'), inst = phInst(instId);
    const filas = xs.map(x => { const cantidad = Math.round(rcNum(x.cantidad)); return { fecha: x.fecha, tipo: x.tipo, cantidad, tarifa: x.tarifa, subtotal: cantidad * x.tarifa }; });
    try { hechos.push(await rcGuardarRecibo(inst, metodosDe(inst)[0]?.value || '', filas, modo === 'caja', '')); }
    catch (e) { fallas.push(`${inst?.nombre}: ${mensajeErr(e)}`); }
  }
  window._rcUltimos = hechos;
  const total = hechos.reduce((s, g) => s + Number(g.monto || 0), 0);
  rcAviso = { tipo: fallas.length ? 'err' : 'ok', html: `${hechos.length ? `✅ ${hechos.length} recibo(s) registrados por ${fmtCRC(total)}.` : ''}${fallas.length ? ' ⚠ No se pudieron registrar: ' + esc(fallas.join('; ')) : ''}`
    + (hechos.length ? ' <button class="btn-ghost" style="margin-left:8px;" onclick="rcReciboPDF(window._rcUltimos)">📄 Imprimir recibos</button>' : '') };
  rcPrevia = null;
  rcRender(); piRecargarGastos();
}

// ── 3) Plantilla semanal (editable) ──
function rcRenderPlantilla() {
  const el = document.getElementById('rcPlantillaCard'); if (!el) return;
  const opcTipo = sel => piTarifas.map(t => `<option value="${t.id}"${t.id === sel ? ' selected' : ''}>${esc(t.tipo)}</option>`).join('');
  el.innerHTML = `
    <details ${rcPlantilla.length && !rcPlantillaCambios ? '' : 'open'}>
      <summary style="cursor:pointer;font-weight:600;">🗓️ Plantilla semanal <span class="hint" style="font-weight:400;">— clases fijas de cada instructor por día (${rcPlantilla.length} fila${rcPlantilla.length === 1 ? '' : 's'})</span></summary>
      <div class="g-wrap" style="margin:12px 0 0;"><table class="g-table ph-tabla">
        <thead><tr><th class="ph-nombre">Instructor</th><th>Tipo</th>${RC_DIAS.map(d => `<th class="num">${d}</th>`).join('')}<th></th></tr></thead>
        <tbody>${rcPlantilla.map((p, i) => `<tr>
          <td class="ph-nombre"><b>${esc(phInst(p.instructor_id)?.nombre || '—')}</b></td>
          <td><select class="ui ph-tarifa" aria-label="Tipo de clase" onchange="rcPlantilla[${i}].tarifa_id=this.value; rcPlantillaCambios=true;">${opcTipo(p.tarifa_id)}</select></td>
          ${p.dias.map((n, d) => `<td class="num"><input class="ph-dia" inputmode="numeric" aria-label="${RC_DIAS[d]}" value="${rcNum(n) || ''}" placeholder="0" oninput="rcPlantilla[${i}].dias[${d}]=Math.round(rcNum(this.value)); rcPlantillaCambios=true;"></td>`).join('')}
          <td class="num"><button class="btn-del" aria-label="Quitar" onclick="rcPlantilla.splice(${i},1); rcPlantillaCambios=true; rcRenderPlantilla();">✕</button></td>
        </tr>`).join('') || `<tr><td colspan="10" class="g-empty">Sin filas. Agregue a los instructores con sus clases fijas.</td></tr>`}</tbody>
      </table></div>
      <div class="hint" style="margin-top:6px;">Cada casilla = cantidad de clases de ese tipo ese día. En blanco = no da clase.</div>
      <div style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-top:10px;">
        <select class="ui" id="rcPInst" aria-label="Instructor" style="max-width:260px;"><option value="">— Agregar instructor —</option>${instructores.map(i => `<option value="${i.id}">${esc(i.nombre)}</option>`).join('')}</select>
        <select class="ui" id="rcPTipo" aria-label="Tipo de clase">${opcTipo(piTarifas[0]?.id)}</select>
        <button class="btn-ghost" onclick="rcAgregarPlantilla()">＋ Agregar</button>
        <span style="margin-left:auto;" class="form-msg" id="rcPlMsg"></span>
        <button class="btn-primary" onclick="rcGuardarPlantilla()">📌 Guardar plantilla</button>
      </div>
    </details>`;
}
function rcAgregarPlantilla() {
  const inst = document.getElementById('rcPInst').value, tipo = document.getElementById('rcPTipo').value;
  if (!inst || !tipo) return;
  if (rcPlantilla.some(p => p.instructor_id === inst && p.tarifa_id === tipo)) { alert('Ese instructor ya tiene una fila con ese tipo de clase.'); return; }
  rcPlantilla.push({ instructor_id: inst, tarifa_id: tipo, dias: [0, 0, 0, 0, 0, 0, 0] });
  rcPlantillaCambios = true; rcRenderPlantilla();
}
async function rcGuardarPlantilla() {
  const msg = document.getElementById('rcPlMsg');
  const claves = rcPlantilla.map(p => p.instructor_id + '|' + p.tarifa_id);
  if (new Set(claves).size !== claves.length) { msg.className = 'form-msg err'; msg.textContent = 'Hay filas repetidas (mismo instructor y tipo).'; return; }
  try {
    await rcGuardarPlantillaTipo('recibo', rcPlantilla.filter(p => p.dias.some(n => rcNum(n) > 0)));
    rcAviso = { tipo: 'ok', html: '✅ Plantilla guardada.' };
    await rcCargar();
  } catch (e) { msg.className = 'form-msg err'; msg.textContent = 'No se pudo guardar: ' + mensajeErr(e); }
}
// Reemplaza la plantilla de un tipo ('recibo' u 'horas') de la sede por estas filas
async function rcGuardarPlantillaTipo(tipo, filas) {
  await supaFetch(`/plantillas_pago?sede=eq.${encodeURIComponent(currentSede)}&tipo=eq.${tipo}`, { method: 'DELETE' });
  if (filas.length) await supaFetch('/plantillas_pago', { method: 'POST', body: filas.map(p => ({
    sede: currentSede, tipo, instructor_id: p.instructor_id, tarifa_id: p.tarifa_id, dias: p.dias.map(n => tipo === 'recibo' ? Math.round(rcNum(n)) : rcNum(n)) })) });
}

// Después de crear una persona con «＋» (modal de gastos.html)
function rcTrasNuevoInstructor(id) {
  if (piTab !== 'recibos' || !rcF) return;
  rcF.instructor_id = id; rcRenderManual();
}

// ── Recibo en PDF (para firmar) ──
// gastos: filas de gastos con origen 'recibo' (detalle_clases, monto, banco_pago, cuenta_pago, dia_pago, …)
function rcReciboPDF(gastos) {
  gastos = (gastos || []).filter(Boolean);
  if (!gastos.length) return;
  if (!window.jspdf) { alert('No se pudo cargar el generador de PDF. Revise la conexión.'); return; }
  const { jsPDF } = window.jspdf; const doc = new jsPDF({ unit: 'pt', format: 'a4' });
  const money = n => 'CRC ' + Math.round(Number(n) || 0).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
  const sin = s => String(s ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '');
  gastos.forEach((g, k) => {
    if (k) doc.addPage();
    const X = 56, W = 483; let y = 56;
    const ins = phInst(g.instructor_id), fis = piFiscal[g.sede];
    doc.setFillColor(14, 159, 142); doc.roundedRect(X, y, W, 62, 8, 8, 'F');
    doc.setTextColor(255); doc.setFont('helvetica', 'bold'); doc.setFontSize(17);
    doc.text('RECIBO DE PAGO POR CLASES', X + 18, y + 27);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(10.5);
    doc.text(sin(`Impulse Fit · Sede ${g.sede}${fis?.razon_social ? ' · ' + fis.razon_social : ''}`), X + 18, y + 46);
    doc.setFontSize(10);
    doc.text(sin(g.pago_tipo === 'caja' ? 'Pago de caja' : (g.dia_pago ? 'Pago: ' + piFechaLarga(parseFecha(g.dia_pago)) : '')), X + W - 18, y + 46, { align: 'right' });
    y += 90;
    const dato = (t, v, x) => { doc.setFont('helvetica', 'normal'); doc.setFontSize(9); doc.setTextColor(120); doc.text(t, x, y);
      doc.setFont('helvetica', 'bold'); doc.setFontSize(11); doc.setTextColor(30); doc.text(sin(v || '—'), x, y + 15); };
    dato('Nombre', ins?.nombre || g.emisor, X); dato('Cedula', ins?.cedula || g.emisor_cedula, X + 300); y += 36;
    dato('Se paga a', [g.banco_pago, g.cuenta_pago].filter(Boolean).join(' · '), X); y += 44;
    const cols = [X + 12, X + 150, X + 330, X + 400, X + W - 12];
    doc.setFillColor(221, 242, 228); doc.rect(X, y, W, 22, 'F');
    doc.setFont('helvetica', 'bold'); doc.setFontSize(10); doc.setTextColor(40);
    doc.text('Fecha', cols[0], y + 15); doc.text('Clase', cols[1], y + 15); doc.text('Cant.', cols[2], y + 15); doc.text('Tarifa', cols[3], y + 15); doc.text('Subtotal', cols[4], y + 15, { align: 'right' });
    y += 22; doc.setFont('helvetica', 'normal'); doc.setFontSize(10.5);
    (Array.isArray(g.detalle_clases) ? g.detalle_clases : []).forEach(c => {
      doc.setDrawColor(225); doc.line(X, y + 22, X + W, y + 22); doc.setTextColor(50);
      doc.text(sin(parseFecha(c.fecha).toLocaleDateString('es-CR', { weekday: 'short', day: 'numeric', month: 'short' })), cols[0], y + 15);
      doc.text(sin(c.tipo), cols[1], y + 15); doc.text(String(c.cantidad), cols[2], y + 15);
      doc.text(money(c.tarifa), cols[3], y + 15); doc.text(money(c.subtotal), cols[4], y + 15, { align: 'right' });
      y += 22;
    });
    y += 14;
    doc.setFillColor(14, 159, 142); doc.roundedRect(X, y, W, 40, 8, 8, 'F');
    doc.setTextColor(255); doc.setFont('helvetica', 'bold'); doc.setFontSize(13);
    doc.text('TOTAL A PAGAR', X + 16, y + 25); doc.setFontSize(16); doc.text(money(g.monto), X + W - 16, y + 26, { align: 'right' });
    y += 64;
    doc.setTextColor(90); doc.setFont('helvetica', 'normal'); doc.setFontSize(9.5);
    if (g.nota_diferencia) { doc.splitTextToSize('Nota: ' + sin(g.nota_diferencia), W).forEach(l => { doc.text(l, X, y); y += 13; }); y += 6; }
    doc.text(g.pagado_at ? `Pagado el ${new Date(g.pagado_at).toLocaleString('es-CR')}.` : 'Pendiente de pago.', X, y);
    y += 70;
    doc.setDrawColor(150); doc.line(X, y, X + 220, y); doc.line(X + W - 220, y, X + W, y);
    doc.setFontSize(9); doc.text('Recibido conforme (firma)', X, y + 14); doc.text('Entregado por', X + W - 220, y + 14);
    doc.setFontSize(8.5); doc.setTextColor(140); doc.text(`Generado el ${new Date().toLocaleString('es-CR')}`, X, 800);
  });
  const g0 = gastos[0];
  doc.save(gastos.length === 1 ? `recibo_${g0.fecha_clase}_${phSlug(phInst(g0.instructor_id)?.nombre || g0.emisor)}.pdf` : `recibos_${phSlug(currentSede)}_${piYMD(piAhoraCR())}.pdf`);
}
