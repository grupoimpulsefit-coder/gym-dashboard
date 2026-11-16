/* ══════════════════════════════════════════════════════════════════════════
   horas_instructores.js — Planilla por horas: instructores que no facturan y
   se les paga cada viernes por las horas de la semana anterior (lun–dom).
   Pestaña «🕐 Horas» de gastos.html. Base: horas_instructores.sql.

   · Coordinador / recepción anotan las horas por día y envían a aprobación.
   · Un admin puede anotar también (emergencias), aprueba o reabre.
   · Al aprobar, cada persona queda como gasto de «Instructores de planta» y
     aparece en «Pago de la semana» (viernes), con recibo PDF.
   Usa lo de gastos.html y pagos_instructores.js / factura_xml.js.
   ══════════════════════════════════════════════════════════════════════════ */

let phSemana = null;    // lunes de la semana que se muestra
let phFilas = [];       // filas de la tabla
let phCargadas = [];    // ids que venían de la base (para borrar las que se quitan)
let phEnviadas = [];    // admin: semanas enviadas que esperan aprobación
let phCambios = false;  // hay cambios sin guardar
let phAviso = null;
let phPlantilla = [];     // plantilla de horas de la sede (plantillas_pago, tipo 'horas')
let phDesdePlantilla = false;
const PH_DIAS = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
const phPago = lunes => piSumarDias(lunes, 11);   // viernes siguiente a la semana trabajada
const phNum = v => { const n = Number(String(v ?? '').replace(',', '.')); return isFinite(n) && n > 0 ? n : 0; };
const phHoras = f => f.dias.reduce((s, h) => s + phNum(h), 0);
const phTarifaDe = f => f.estado === 'aprobada' ? Number(f.tarifa) || 0 : Number(piHoraTarifas.find(t => t.id === f.tarifa_id)?.monto) || 0;
const phTotal = f => Math.max(0, phHoras(f) * phTarifaDe(f) - (Number(f.deduccion) || 0));
const phInst = id => instructores.find(i => i.id === id) || null;
const phRango = l => { const d = piSumarDias(l, 6); return `${l.getDate()}${l.getMonth() !== d.getMonth() ? ' de ' + l.toLocaleDateString('es-CR', { month: 'long' }) : ''} al ${d.getDate()} de ${d.toLocaleDateString('es-CR', { month: 'long' })}`; };

// Lunes a viernes se trabaja la semana anterior (se paga este viernes); sábado y domingo, la actual
function phSemanaInicial() {
  const hoy = piAhoraCR(), lun = piLunes(hoy);
  phSemana = [6, 0].includes(hoy.getDay()) ? lun : piSumarDias(lun, -7);
}

async function phCargar() {
  if (!phSemana) phSemanaInicial();
  const v = document.getElementById('vista_horas');
  v.innerHTML = '<div class="loading" style="display:block;"><div class="spinner"></div><div>Cargando horas…</div></div>';
  try {
    if (!piHoraTarifas.length) await piCargarCatalogos();
    const rows = (await supaFetch(`/horas_semana?sede=eq.${encodeURIComponent(currentSede)}&semana=eq.${piYMD(phSemana)}&select=*`)) || [];
    phCargadas = rows.map(r => r.id);
    phFilas = rows.map(r => ({ ...r, dias: Array.isArray(r.dias) ? r.dias.map(Number) : [0, 0, 0, 0, 0, 0, 0], clave0: r.instructor_id + '|' + r.tarifa_id }));
    try {
      phPlantilla = ((await supaFetch(`/plantillas_pago?sede=eq.${encodeURIComponent(currentSede)}&tipo=eq.horas&select=*`)) || [])
        .map(p => ({ ...p, dias: Array.isArray(p.dias) ? p.dias.map(Number) : [0, 0, 0, 0, 0, 0, 0] }));
    } catch (_) { phPlantilla = []; }
    // Semana nueva (nada guardado): se llena sola con la plantilla de la sede
    phDesdePlantilla = false;
    if (!rows.length && phPlantilla.length) {
      phPlantilla.forEach(p => { if (phInst(p.instructor_id)) phFilas.push({ ...phFilaNueva(p.instructor_id, p.tarifa_id), dias: [...p.dias] }); });
      phDesdePlantilla = true;
    }
    // Las personas que cobran por horas en esta sede aparecen solas, en blanco
    if (!phFilas.some(f => f.estado === 'aprobada')) {
      instructores.filter(i => i.hora_sede === currentSede && i.hora_tarifa_id && !phFilas.some(f => f.instructor_id === i.id))
        .forEach(i => phFilas.push(phFilaNueva(i.id, i.hora_tarifa_id)));
    }
    phFilas.sort((a, b) => (phInst(a.instructor_id)?.nombre || '').localeCompare(phInst(b.instructor_id)?.nombre || '', 'es'));
    if (esAdmin()) phEnviadas = (await supaFetch('/horas_semana?estado=eq.enviada&select=sede,semana')) || [];
    phCambios = false;
    phRender();
  } catch (e) {
    v.innerHTML = `<div class="empty-state" style="display:block;">⚠️ No se pudieron cargar las horas: ${esc(e.message)}`
      + (/horas_semana|hora_tarifas|relation|schema/i.test(e.message) ? '<br>¿Ya se corrió horas_instructores.sql en Supabase?' : '') + '</div>';
  }
}
function phFilaNueva(instructorId, tarifaId) {
  return { instructor_id: instructorId, tarifa_id: tarifaId || piHoraTarifas[0]?.id || '', dias: [0, 0, 0, 0, 0, 0, 0], deduccion: 0, nota: '', estado: 'nuevo' };
}

async function phContar() {
  if (!esAdmin()) return;
  try {
    const r = (await supaFetch('/horas_semana?estado=eq.enviada&select=sede,semana')) || [];
    const n = new Set(r.map(x => x.sede + x.semana)).size;
    document.getElementById('phCount').innerHTML = n ? `<span class="pill pend" style="height:20px;padding:0 7px;">${n}</span>` : '';
  } catch (_) {}
}

function phEstadoSemana() {
  if (!phFilas.some(f => f.id)) return { txt: 'Sin guardar', pill: '' };
  const guardadas = phFilas.filter(f => f.id);
  if (guardadas.every(f => f.estado === 'aprobada')) {
    const a = guardadas[0];
    return { txt: `Aprobada${a.aprobado_por ? ' por ' + a.aprobado_por : ''}`, pill: 'ok' };
  }
  if (guardadas.some(f => f.estado === 'enviada')) return { txt: 'Enviada a aprobación', pill: 'info' };
  return { txt: 'Borrador', pill: 'pend' };
}

function phRender() {
  const v = document.getElementById('vista_horas');
  const adm = esAdmin();
  const est = phEstadoSemana();
  const editables = phFilas.filter(f => f.estado !== 'aprobada');
  const hayAprobadas = phFilas.some(f => f.estado === 'aprobada');
  const aviso = phAviso; phAviso = null;
  const fechas = PH_DIAS.map((d, i) => `${d} ${piSumarDias(phSemana, i).getDate()}`);
  const opcTarifa = sel => piHoraTarifas.map(t => `<option value="${t.id}"${t.id === sel ? ' selected' : ''}>${esc(t.tipo)} (${fmtCRC(t.monto)}/h)</option>`).join('');
  // Semanas enviadas por las sedes (admin)
  const grupos = {};
  phEnviadas.forEach(x => { const k = x.sede + '|' + x.semana; grupos[k] = (grupos[k] || 0) + 1; });
  const enviadasHtml = adm && Object.keys(grupos).length ? `
    <div class="form-card" style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;border:1.5px solid var(--blue);">
      <b style="margin-right:4px;">Esperando su aprobación:</b>
      ${Object.entries(grupos).map(([k, n]) => { const [s, sem] = k.split('|'); return `<button class="btn-ghost" onclick="phIr('${esc(s)}','${sem}')">${esc(s)} · ${esc(phRango(parseFecha(sem)))} (${n})</button>`; }).join('')}
    </div>` : '';

  const filas = phFilas.map((f, i) => {
    const ins = phInst(f.instructor_id);
    const ro = f.estado === 'aprobada';
    const dis = ro ? 'disabled' : '';
    return `<tr${ro ? ' style="background:var(--fill);"' : ''}>
      <td class="ph-nombre"><b>${esc(ins?.nombre || '—')}</b>${ro ? ' <span class="pill ok">Aprobada</span>' : ''}
        <div style="margin-top:4px;">${ro ? `<span class="hint">${esc(f.tipo)} · ${fmtCRC(f.tarifa)}/h</span>`
          : `<select class="ui ph-tarifa" aria-label="Tarifa de ${esc(ins?.nombre || '')}" onchange="phCambiar(${i},'tarifa_id',this.value)">${opcTarifa(f.tarifa_id)}</select>`}</div></td>
      ${f.dias.map((h, d) => `<td class="num"><input class="ph-dia" inputmode="decimal" aria-label="${fechas[d]}" value="${phNum(h) || ''}" placeholder="0" ${dis} oninput="phDia(${i},${d},this.value)"></td>`).join('')}
      <td class="num"><b id="phH${i}">${phHoras(f)}</b></td>
      ${adm ? `<td class="num"><input class="ph-dia" style="width:70px;" inputmode="numeric" aria-label="Rebajo" value="${Number(f.deduccion) || ''}" placeholder="0" ${dis} oninput="phCambiar(${i},'deduccion',this.value)"></td>` : ''}
      <td class="num"><b id="phT${i}">${fmtCRC(phTotal(f))}</b></td>
      <td><input aria-label="Nota" value="${esc(f.nota || '')}" placeholder="Opcional" ${dis} style="width:100px;text-align:left;" oninput="phCambiar(${i},'nota',this.value)"></td>
      <td class="num">${ro ? '' : `<button class="btn-del" aria-label="Quitar a ${esc(ins?.nombre || '')}" title="Quitar" onclick="phQuitar(${i})">✕</button>`}</td>
    </tr>`;
  }).join('');
  const yaEnTabla = new Set(phFilas.map(f => f.instructor_id));
  const disponibles = instructores.filter(i => !yaEnTabla.has(i.id));

  v.innerHTML = `
    <div class="section" style="display:flex;flex-wrap:wrap;gap:10px;align-items:center;">
      <div class="section-title" style="margin:0;">🕐 Planilla por horas <span class="section-note">— ${esc(currentSede)} · instructores que no facturan</span></div>
      <span style="margin-left:auto;display:flex;gap:6px;align-items:center;">
        <button class="btn-ghost" onclick="phMover(-7)" aria-label="Semana anterior">‹</button>
        <span style="font-weight:600;font-size:14px;min-width:150px;text-align:center;">Semana del ${esc(phRango(phSemana))}</span>
        <button class="btn-ghost" onclick="phMover(7)" aria-label="Semana siguiente">›</button>
      </span>
    </div>
    ${enviadasHtml}
    ${aviso ? `<div class="section" style="padding-top:0;"><div class="form-msg ${aviso.tipo}" style="font-size:15px;">${esc(aviso.texto)}</div></div>` : ''}
    <div class="kpi-row" style="padding-top:4px;">
      <div class="kpi"><div class="kpi-label">Estado</div><div style="margin-top:8px;"><span class="pill ${est.pill}" style="font-size:14px;height:28px;">${esc(est.txt)}</span></div></div>
      <div class="kpi"><div class="kpi-label">Se paga el</div><div class="kpi-value" style="font-size:20px;">${esc(piFechaLarga(phPago(phSemana)))}</div><div class="kpi-sub">en «Pago de la semana»</div></div>
      <div class="kpi"><div class="kpi-label">Horas de la semana</div><div class="kpi-value" id="phTotH">${phFilas.reduce((s, f) => s + phHoras(f), 0)}</div></div>
      <div class="kpi teal"><div class="kpi-label">Total a pagar</div><div class="kpi-value" id="phTotM">${fmtCRC(phFilas.reduce((s, f) => s + phTotal(f), 0))}</div></div>
    </div>
    ${phDesdePlantilla ? '<div class="section" style="padding-bottom:0;"><div class="pay-box" style="border-color:var(--blue);">📋 Semana llenada con la plantilla. Corrija lo que cambió y toque <b>Guardar</b> o <b>Enviar a aprobación</b>: hasta entonces no queda guardada.</div></div>' : ''}
    <div class="section" style="padding-bottom:0;"><div class="hint">Anote las horas de cada día (se aceptan medias horas: 1.5). Las casillas en blanco cuentan como 0.
      ${adm ? 'La columna «Rebajo» solo la ve un admin (por ahora no se aplican deducciones).' : ''}</div></div>
    <div class="section"><div class="g-wrap" style="margin:0;">
      <table class="g-table ph-tabla">
        <thead><tr><th class="ph-nombre">Persona y tarifa</th>${fechas.map(d => `<th class="num">${d}</th>`).join('')}<th class="num">Horas</th>${adm ? '<th class="num">Rebajo</th>' : ''}<th class="num">Total</th><th>Nota</th><th></th></tr></thead>
        <tbody>${filas || `<tr><td colspan="${adm ? 13 : 12}" class="g-empty">Nadie en la planilla de esta semana. Agregue a las personas abajo.</td></tr>`}</tbody>
      </table>
    </div></div>
    <div class="section" style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding-top:0;">
      <select class="ui" id="phAgregarSel" aria-label="Persona para agregar" style="max-width:280px;">
        <option value="">— Agregar persona del directorio —</option>
        ${disponibles.map(i => `<option value="${i.id}">${esc(i.nombre)}</option>`).join('')}
      </select>
      <button class="btn-ghost" onclick="phAgregar()">＋ Agregar</button>
      <button class="btn-ghost" onclick="openInstructorModal()" title="Crear una persona nueva en el directorio">＋ Persona nueva</button>
      <span style="margin-left:auto;display:flex;flex-wrap:wrap;gap:8px;">
        ${editables.length && phPlantilla.length ? '<button class="btn-ghost" onclick="phLlenarPlantilla()" title="Pone en la tabla las horas fijas de la plantilla">📋 Llenar con la plantilla</button>' : ''}
        ${phFilas.length ? '<button class="btn-ghost" onclick="phGuardarPlantilla()" title="Guarda las horas de esta semana como las horas fijas de cada persona">📌 Guardar como plantilla</button>' : ''}
      </span>
    </div>
    <div class="form-actions" style="padding:0 var(--gut) 24px;">
      <div class="form-msg" id="phMsg"></div>
      ${hayAprobadas && adm ? '<button class="btn-ghost" onclick="phReabrir()">↺ Reabrir semana</button>' : ''}
      ${hayAprobadas ? '<button class="btn-ghost" onclick="phRecibosSemana()">📄 Recibos PDF</button>' : ''}
      ${editables.length ? `<button class="btn-ghost" id="phBtnGuardar" onclick="phGuardar()">💾 Guardar</button>
        ${adm ? '<button class="btn-primary" id="phBtnAprobar" onclick="phAprobar()">✓ Aprobar y enviar a pago</button>'
              : '<button class="btn-primary" id="phBtnEnviar" onclick="phGuardar(\'enviada\')">📤 Enviar a aprobación</button>'}` : ''}
    </div>`;
}

function phRecalcular(i) {
  const f = phFilas[i];
  const h = document.getElementById('phH' + i), t = document.getElementById('phT' + i);
  if (h) h.textContent = phHoras(f);
  if (t) t.textContent = fmtCRC(phTotal(f));
  document.getElementById('phTotH').textContent = phFilas.reduce((s, x) => s + phHoras(x), 0);
  document.getElementById('phTotM').textContent = fmtCRC(phFilas.reduce((s, x) => s + phTotal(x), 0));
  const m = document.getElementById('phMsg'); if (m) { m.className = 'form-msg'; m.textContent = 'Hay cambios sin guardar.'; }
}
function phDia(i, d, valor) { phFilas[i].dias[d] = phNum(valor); phCambios = true; phRecalcular(i); }
function phCambiar(i, campo, valor) { phFilas[i][campo] = campo === 'deduccion' ? phNum(valor) : valor; phCambios = true; phRecalcular(i); }
function phQuitar(i) {
  const f = phFilas[i];
  if (phHoras(f) > 0 && !confirm(`¿Quitar a ${phInst(f.instructor_id)?.nombre || 'esta persona'} de la semana?`)) return;
  phFilas.splice(i, 1); phCambios = true; phRender();
  const m = document.getElementById('phMsg'); if (m) m.textContent = 'Hay cambios sin guardar.';
}
function phAgregar() {
  const id = document.getElementById('phAgregarSel').value;
  if (!id) return;
  phFilas.push(phFilaNueva(id, phInst(id)?.hora_tarifa_id));
  phCambios = true; phRender();
}
// Después de crear una persona con «＋ Persona nueva» (modal de gastos.html)
function phTrasNuevoInstructor(id) {
  if (piTab !== 'horas' || !id || phFilas.some(f => f.instructor_id === id)) return;
  phFilas.push(phFilaNueva(id)); phCambios = true; phRender();
}
function phMover(n) {
  if (phCambios && !confirm('Hay cambios sin guardar en esta semana. ¿Salir sin guardar?')) return;
  phSemana = piSumarDias(phSemana, n); phCargar();
}
function phIr(sede, semana) {
  if (phCambios && !confirm('Hay cambios sin guardar en esta semana. ¿Salir sin guardar?')) return;
  if (sede !== currentSede && SEDES.includes(sede)) {
    currentSede = sede;
    const sel = document.getElementById('sedeSelector'); if (sel) sel.value = sede;
    piRecargarGastos();
  }
  phSemana = parseFecha(semana); phCargar();
}

// ── Plantilla de horas (las horas fijas de cada persona por día) ──
function phLlenarPlantilla() {
  const pisa = phPlantilla.some(p => phFilas.some(f => f.estado !== 'aprobada' && f.instructor_id === p.instructor_id && f.tarifa_id === p.tarifa_id && phHoras(f) > 0));
  if (pisa && !confirm('Algunas personas ya tienen horas anotadas esta semana. ¿Reemplazarlas por las de la plantilla?')) return;
  phPlantilla.forEach(p => {
    if (!phInst(p.instructor_id)) return;
    const f = phFilas.find(x => x.estado !== 'aprobada' && x.instructor_id === p.instructor_id && x.tarifa_id === p.tarifa_id);
    if (f) f.dias = [...p.dias];
    else if (!phFilas.some(x => x.estado === 'aprobada' && x.instructor_id === p.instructor_id && x.tarifa_id === p.tarifa_id))
      phFilas.push({ ...phFilaNueva(p.instructor_id, p.tarifa_id), dias: [...p.dias] });
  });
  phCambios = true; phRender();
  const m = document.getElementById('phMsg'); if (m) { m.className = 'form-msg'; m.textContent = 'Llenada con la plantilla: revise y guarde.'; }
}
async function phGuardarPlantilla() {
  const filas = phFilas.filter(f => phHoras(f) > 0 && f.tarifa_id);
  if (!filas.length) { const m = document.getElementById('phMsg'); if (m) { m.className = 'form-msg err'; m.textContent = 'Anote las horas fijas antes de guardarlas como plantilla.'; } return; }
  if (!confirm(`¿Guardar las horas de esta semana (${filas.length} persona${filas.length === 1 ? '' : 's'}) como la plantilla de ${currentSede}?\nReemplaza la plantilla anterior. Las semanas nuevas se llenarán solas con estas horas.`)) return;
  try {
    await rcGuardarPlantillaTipo('horas', filas.map(f => ({ instructor_id: f.instructor_id, tarifa_id: f.tarifa_id, dias: f.dias })));
    phPlantilla = filas.map(f => ({ instructor_id: f.instructor_id, tarifa_id: f.tarifa_id, dias: [...f.dias] }));
    const m = document.getElementById('phMsg'); if (m) { m.className = 'form-msg ok'; m.textContent = '✅ Plantilla guardada.'; }
  } catch (e) {
    const m = document.getElementById('phMsg'); if (m) { m.className = 'form-msg err'; m.textContent = /plantillas_pago|relation/i.test(e.message) ? 'Falta correr recibos_plantillas.sql en Supabase.' : 'No se pudo guardar la plantilla: ' + e.message; }
  }
}

// Guarda la semana; con estado 'enviada' además la manda a aprobación
async function phGuardar(estado, silencioso) {
  const msg = document.getElementById('phMsg');
  const editables = phFilas.filter(f => f.estado !== 'aprobada');
  const claves = editables.map(f => f.instructor_id + '|' + f.tarifa_id);
  if (editables.some(f => !f.tarifa_id)) { msg.className = 'form-msg err'; msg.textContent = 'Elija la tarifa de cada persona.'; return false; }
  if (new Set(claves).size !== claves.length) { msg.className = 'form-msg err'; msg.textContent = 'Hay una persona repetida con la misma tarifa: deje una sola fila.'; return false; }
  if (editables.some(f => f.dias.some(h => phNum(h) > 24))) { msg.className = 'form-msg err'; msg.textContent = 'Un día no puede tener más de 24 horas.'; return false; }
  const conHoras = editables.filter(f => phHoras(f) > 0);
  if (estado === 'enviada' && !conHoras.length) { msg.className = 'form-msg err'; msg.textContent = 'Anote las horas antes de enviar.'; return false; }
  // Se borran las filas que se quitaron, quedaron en 0 o cambiaron de tarifa
  const siguen = new Set(conHoras.filter(f => f.id && f.clave0 === f.instructor_id + '|' + f.tarifa_id).map(f => f.id));
  const aprobadas = new Set(phFilas.filter(f => f.estado === 'aprobada').map(f => f.id));
  const borrar = phCargadas.filter(id => !siguen.has(id) && !aprobadas.has(id));
  document.querySelectorAll('#vista_horas .form-actions button').forEach(b => { b.disabled = true; });
  try {
    if (borrar.length) await supaFetch(`/horas_semana?id=in.(${borrar.join(',')})`, { method: 'DELETE' });
    if (conHoras.length) {
      await supaFetch('/horas_semana?on_conflict=sede,semana,instructor_id,tarifa_id', {
        method: 'POST', prefer: 'resolution=merge-duplicates,return=minimal',
        body: conHoras.map(f => ({
          sede: currentSede, semana: piYMD(phSemana), instructor_id: f.instructor_id, tarifa_id: f.tarifa_id,
          dias: f.dias.map(phNum), deduccion: Number(f.deduccion) || 0, nota: (f.nota || '').trim() || null,
          estado: estado || (f.estado === 'enviada' ? 'enviada' : 'borrador'),
        })),
      });
    }
    phCambios = false;
    if (!silencioso) {
      phAviso = { tipo: 'ok', texto: estado === 'enviada' ? '✅ Horas enviadas a aprobación. Un admin las revisa antes del viernes.' : '✅ Horas guardadas.' };
      await phCargar(); phContar();
    }
    return true;
  } catch (e) {
    document.querySelectorAll('#vista_horas .form-actions button').forEach(b => { b.disabled = false; });
    msg.className = 'form-msg err';
    msg.textContent = 'No se pudo guardar: ' + e.message;
    return false;
  }
}

async function phAprobar() {
  const editables = phFilas.filter(f => f.estado !== 'aprobada' && phHoras(f) > 0);
  if (!editables.length) { const m = document.getElementById('phMsg'); m.className = 'form-msg err'; m.textContent = 'No hay horas para aprobar.'; return; }
  const total = editables.reduce((s, f) => s + phTotal(f), 0);
  const sinCuenta = editables.filter(f => { const i = phInst(f.instructor_id); return i && !metodosDe(i).length; }).map(f => phInst(f.instructor_id).nombre);
  if (!confirm(`¿Aprobar ${editables.length} persona(s) por ${fmtCRC(total)}?\nSe pagan el ${piFechaLarga(phPago(phSemana))}.`
    + (sinCuenta.length ? `\n\nOjo: ${sinCuenta.join(', ')} no tiene(n) cuenta ni SINPE en el directorio.` : ''))) return;
  if (!(await phGuardar(null, true))) return;
  try {
    const n = await supaFetch('/rpc/aprobar_horas', { method: 'POST', body: { p_sede: currentSede, p_semana: piYMD(phSemana) }, prefer: 'return=representation' });
    phAviso = { tipo: 'ok', texto: `✅ Semana aprobada: ${n} persona(s). Aparecen en «Pago de la semana» del ${piFechaLarga(phPago(phSemana))}.` };
    await phCargar(); phContar(); piRecargarGastos();
  } catch (e) {
    phAviso = { tipo: 'err', texto: 'No se pudo aprobar: ' + e.message };
    await phCargar();
  }
}

async function phReabrir() {
  if (!confirm('¿Reabrir la semana? Se quitan sus pagos de «Pago de la semana» y de Gastos hasta que se vuelva a aprobar.')) return;
  try {
    await supaFetch('/rpc/reabrir_horas', { method: 'POST', body: { p_sede: currentSede, p_semana: piYMD(phSemana) }, prefer: 'return=representation' });
    phAviso = { tipo: 'ok', texto: 'Semana reabierta: se puede corregir y volver a aprobar.' };
    await phCargar(); phContar(); piRecargarGastos();
  } catch (e) { phAviso = { tipo: 'err', texto: e.message }; phRender(); }
}

// ── Recibo de pago por horas (PDF): sustituye a la factura como respaldo ──
// datos: [{ nombre, cedula, sede, semana, tipo, tarifa, dias, horas, deduccion, banco, cuenta, dia_pago, pagado_at, nota }]
function phReciboPDF(datos, archivo) {
  if (!window.jspdf) { alert('No se pudo cargar el generador de PDF. Revise la conexión.'); return; }
  const { jsPDF } = window.jspdf; const doc = new jsPDF({ unit: 'pt', format: 'a4' });
  const money = n => 'CRC ' + Math.round(Number(n) || 0).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
  datos.forEach((r, k) => {
    if (k) doc.addPage();
    const X = 56, W = 483; let y = 56;
    const lun = parseFecha(r.semana);
    doc.setFillColor(14, 159, 142); doc.roundedRect(X, y, W, 62, 8, 8, 'F');
    doc.setTextColor(255); doc.setFont('helvetica', 'bold'); doc.setFontSize(17);
    doc.text('RECIBO DE PAGO POR HORAS', X + 18, y + 27);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(10.5);
    doc.text(`Impulse Fit · Sede ${r.sede}${piFiscal[r.sede]?.razon_social ? ' · ' + piFiscal[r.sede].razon_social : ''}`, X + 18, y + 46);
    doc.setFont('helvetica', 'bold'); doc.setFontSize(10.5);
    doc.text(`Semana del ${phRango(lun)}`, X + W - 18, y + 27, { align: 'right' });
    doc.setFont('helvetica', 'normal'); doc.setFontSize(10);
    doc.text(`Pago: ${r.dia_pago ? piFechaLarga(parseFecha(r.dia_pago)) : ''}`, X + W - 18, y + 46, { align: 'right' });
    y += 90;
    const dato = (k, v, x) => { doc.setFont('helvetica', 'normal'); doc.setFontSize(9); doc.setTextColor(120); doc.text(k, x, y);
      doc.setFont('helvetica', 'bold'); doc.setFontSize(11); doc.setTextColor(30); doc.text(String(v || '—'), x, y + 15); };
    dato('Nombre', r.nombre, X); dato('Cédula', r.cedula, X + 300); y += 36;
    dato('Servicio', r.tipo, X); dato('Tarifa por hora', money(r.tarifa), X + 300); y += 36;
    dato('Se paga a', [r.banco, r.cuenta].filter(Boolean).join(' · '), X); y += 44;
    // Horas por día
    const cw = W / 8;
    doc.setFillColor(221, 242, 228); doc.rect(X, y, W, 22, 'F');
    doc.setFont('helvetica', 'bold'); doc.setFontSize(9.5); doc.setTextColor(40);
    PH_DIAS.forEach((d, i) => doc.text(`${d} ${piSumarDias(lun, i).getDate()}`.normalize('NFD').replace(/[̀-ͯ]/g, ''), X + cw * i + cw / 2, y + 15, { align: 'center' }));
    doc.text('Total', X + cw * 7 + cw / 2, y + 15, { align: 'center' });
    y += 22;
    doc.setFont('helvetica', 'normal'); doc.setFontSize(11);
    (r.dias || []).forEach((h, i) => doc.text(String(Number(h) || 0), X + cw * i + cw / 2, y + 16, { align: 'center' }));
    doc.setFont('helvetica', 'bold'); doc.text(`${r.horas} h`, X + cw * 7 + cw / 2, y + 16, { align: 'center' });
    doc.setDrawColor(225); doc.line(X, y + 24, X + W, y + 24);
    y += 44;
    const linea = (t, v, bold) => { doc.setFont('helvetica', bold ? 'bold' : 'normal'); doc.setFontSize(11); doc.setTextColor(40);
      doc.text(t, X + 12, y); doc.text(v, X + W - 12, y, { align: 'right' }); y += 20; };
    linea(`${r.horas} h x ${money(r.tarifa)}`, money(r.horas * r.tarifa));
    if (Number(r.deduccion)) linea('Rebajos', '- ' + money(r.deduccion));
    y += 4;
    doc.setFillColor(14, 159, 142); doc.roundedRect(X, y, W, 40, 8, 8, 'F');
    doc.setTextColor(255); doc.setFont('helvetica', 'bold'); doc.setFontSize(13);
    doc.text('TOTAL A PAGAR', X + 16, y + 25); doc.setFontSize(16);
    doc.text(money(r.horas * r.tarifa - (Number(r.deduccion) || 0)), X + W - 16, y + 26, { align: 'right' });
    y += 64;
    doc.setTextColor(90); doc.setFont('helvetica', 'normal'); doc.setFontSize(9.5);
    if (r.nota) { doc.splitTextToSize('Nota: ' + r.nota, W).forEach(l => { doc.text(l, X, y); y += 13; }); y += 6; }
    doc.text(r.pagado_at ? `Pagado el ${new Date(r.pagado_at).toLocaleString('es-CR')}.` : 'Pendiente de pago.', X, y);
    y += 70;
    doc.setDrawColor(150); doc.line(X, y, X + 220, y); doc.line(X + W - 220, y, X + W, y);
    doc.setFontSize(9); doc.text('Recibido conforme (firma)', X, y + 14); doc.text('Entregado por', X + W - 220, y + 14);
    doc.setFontSize(8.5); doc.setTextColor(140);
    doc.text(`Generado el ${new Date().toLocaleString('es-CR')}`, X, 800);
  });
  doc.save(archivo);
}
const phSlug = s => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/\s+/g, '_').toLowerCase();

// Recibo desde «Pago de la semana» (fila de gastos con origen 'horas')
function phReciboGasto(g) {
  const d = (Array.isArray(g.detalle_clases) ? g.detalle_clases : [])[0] || {};
  const ins = phInst(g.instructor_id);
  phReciboPDF([{ nombre: ins?.nombre || g.emisor, cedula: ins?.cedula || g.emisor_cedula, sede: g.sede, semana: d.semana,
    tipo: d.tipo, tarifa: d.tarifa, dias: d.dias, horas: d.cantidad, deduccion: d.deduccion, nota: d.nota,
    banco: g.banco_pago, cuenta: g.cuenta_pago, dia_pago: g.dia_pago, pagado_at: g.pagado_at }],
    `recibo_horas_${d.semana}_${phSlug(ins?.nombre || g.emisor)}.pdf`);
}

// Todos los recibos de la semana aprobada
async function phRecibosSemana() {
  const ids = phFilas.filter(f => f.estado === 'aprobada' && f.gasto_id).map(f => f.gasto_id);
  if (!ids.length) return;
  try {
    const gs = (await supaFetch(`/gastos?id=in.(${ids.join(',')})&select=${PI_COLS}`)) || [];
    const datos = gs.map(g => { const d = (g.detalle_clases || [])[0] || {}; const ins = phInst(g.instructor_id);
      return { nombre: ins?.nombre || g.emisor, cedula: ins?.cedula || g.emisor_cedula, sede: g.sede, semana: d.semana, tipo: d.tipo, tarifa: d.tarifa,
        dias: d.dias, horas: d.cantidad, deduccion: d.deduccion, nota: d.nota, banco: g.banco_pago, cuenta: g.cuenta_pago, dia_pago: g.dia_pago, pagado_at: g.pagado_at }; })
      .sort((a, b) => a.nombre.localeCompare(b.nombre, 'es'));
    phReciboPDF(datos, `recibos_horas_${phSlug(currentSede)}_${piYMD(phSemana)}.pdf`);
  } catch (e) { alert('No se pudieron generar los recibos: ' + e.message); }
}

// ── Configuración (admin): tarifas por hora ──
function phConfigHtml() {
  const fila = (t, i) => `<tr>
      <td><input id="phTTipo${i}" value="${esc(t.tipo)}" aria-label="Tipo" style="width:100%;max-width:240px;text-align:left;"></td>
      <td class="num"><input id="phTMonto${i}" type="number" min="1" step="1" value="${esc(t.monto)}" aria-label="Tarifa por hora" style="width:110px;"></td>
      <td class="num" style="white-space:nowrap;"><button class="btn-edit" onclick="phGuardarTarifa('${t.id}', ${i})">💾 Guardar</button>
        <button class="btn-del" onclick="phQuitarTarifa('${t.id}')">Quitar</button></td></tr>`;
  return `
    <div class="form-card">
      <div class="section-title" style="margin-bottom:4px;">Tarifas por hora (planilla por horas)</div>
      <div class="hint" style="margin-bottom:12px;">Para quienes no facturan. Un cambio solo afecta las horas que se guarden después.</div>
      <div class="g-wrap" style="margin:0;"><table class="g-table">
        <thead><tr><th>Tipo</th><th class="num">Tarifa por hora (₡)</th><th></th></tr></thead>
        <tbody>${piHoraTarifas.map(fila).join('')}
          <tr><td><input id="phTTipoN" placeholder="Nuevo tipo" aria-label="Nuevo tipo" style="width:100%;max-width:240px;text-align:left;"></td>
            <td class="num"><input id="phTMontoN" type="number" min="1" step="1" placeholder="0" aria-label="Tarifa del nuevo tipo" style="width:110px;"></td>
            <td class="num"><button class="btn-ok" onclick="phAgregarTarifa()">＋ Agregar</button></td></tr>
        </tbody></table></div>
    </div>`;
}
async function phGuardarTarifa(id, i) {
  const tipo = document.getElementById('phTTipo' + i).value.trim(), monto = Number(document.getElementById('phTMonto' + i).value);
  if (!tipo || !(monto > 0)) { piRenderConfig({ tipo: 'err', texto: 'Indique el tipo y una tarifa válida.' }); return; }
  try { await supaFetch(`/hora_tarifas?id=eq.${encodeURIComponent(id)}`, { method: 'PATCH', body: { tipo, monto } }); await piCargarCatalogos(); piRenderConfig({ tipo: 'ok', texto: `✅ Tarifa por hora de ${tipo} guardada.` }); }
  catch (e) { piRenderConfig({ tipo: 'err', texto: 'No se pudo guardar: ' + e.message }); }
}
async function phQuitarTarifa(id) {
  if (!confirm('¿Quitar esta tarifa por hora? Lo ya aprobado no cambia.')) return;
  try { await supaFetch(`/hora_tarifas?id=eq.${encodeURIComponent(id)}`, { method: 'PATCH', body: { activo: false } }); await piCargarCatalogos(); piRenderConfig({ tipo: 'ok', texto: 'Tarifa quitada.' }); }
  catch (e) { piRenderConfig({ tipo: 'err', texto: 'No se pudo quitar: ' + e.message }); }
}
async function phAgregarTarifa() {
  const tipo = document.getElementById('phTTipoN').value.trim(), monto = Number(document.getElementById('phTMontoN').value);
  if (!tipo || !(monto > 0)) { piRenderConfig({ tipo: 'err', texto: 'Indique el tipo y una tarifa válida.' }); return; }
  try {
    const previa = piHoraTarifasTodas.find(t => piNorm(t.tipo) === piNorm(tipo));
    if (previa) await supaFetch(`/hora_tarifas?id=eq.${encodeURIComponent(previa.id)}`, { method: 'PATCH', body: { tipo, monto, activo: true } });
    else await supaFetch('/hora_tarifas', { method: 'POST', body: { tipo, monto } });
    await piCargarCatalogos(); piRenderConfig({ tipo: 'ok', texto: `✅ Tarifa por hora de ${tipo} agregada.` });
  } catch (e) { piRenderConfig({ tipo: 'err', texto: 'No se pudo agregar: ' + e.message }); }
}
