/* ══════════════════════════════════════════════════════════════════════════
   pagos_instructores.js — Facturas electrónicas (XML) de instructores de clases
   grupales y pago de la semana (miércoles / viernes / caja).

   Se carga dentro de gastos.html y usa lo de ese módulo: supaFetch,
   supaFetchTodo, currentSede, currentSedes, currentRole, currentEmail,
   instructores, cargarInstructores, metodosDe, esAdmin, fmtCRC, esc,
   parseFecha, mesEtiqueta, mesOrden, renderGastos, poblarMeses, SEDES.
   Base de datos: pagos_instructores.sql.

   El día de pago NO lo decide el navegador: lo pone la base con la hora del
   servidor (corte miércoles y viernes 10:00 a. m., hora de Costa Rica).
   ══════════════════════════════════════════════════════════════════════════ */

let piTab = 'gastos';
let piTarifas = [];        // tarifas activas
let piTarifasTodas = [];   // incluye desactivadas (configuración)
let piFiscal = {};         // sede → { razon_social, cedula_juridica }
let piF = null;            // factura en carga
let piSemana = null;       // lunes de la semana que se muestra en «Pago de la semana»
let piDia = null;          // 'mie' | 'vie' | 'caja'
let piPagos = [];          // gastos XML de la semana
let piAtrasados = [];      // pendientes de semanas anteriores
let piGrupos = [];         // instructores agrupados (pestaña actual)
let piPorAprobar = [];     // facturas enviadas por instructores, esperando aprobación
const piAbiertos = new Set();

const PI_ROLES_PAGAR = ['admin', 'admin_sedes', 'admin_g', 'coordinador', 'admin_sucursal'];
const piPuedePagar = () => PI_ROLES_PAGAR.includes(currentRole);
function piLunes(d) { return piSumarDias(d, -((d.getDay() + 6) % 7)); }
const piFechaCorta = s => s ? parseFecha(s).toLocaleDateString('es-CR', { day: '2-digit', month: '2-digit' }) : '—';
const piHora = s => s ? new Date(s).toLocaleString('es-CR', { day: '2-digit', month: '2-digit', hour: 'numeric', minute: '2-digit' }) : '';


// ── Pestañas ──────────────────────────────────────────────────────────────
function piMostrar(tab) {
  piTab = tab;
  document.querySelectorAll('#piTabs .tab').forEach(b => b.classList.toggle('active', b.dataset.tab === tab));
  document.getElementById('vistaGastos').style.display = tab === 'gastos' ? '' : 'none';
  ['xml', 'aprobar', 'pagos', 'config'].forEach(t => { document.getElementById('vista_' + t).style.display = tab === t ? '' : 'none'; });
  if (tab === 'xml') { piRenderCarga(); if (piF) piValidar(); }
  if (tab === 'aprobar') piCargarPendientes();
  if (tab === 'pagos') piCargarPagos();
  if (tab === 'config') piCargarConfig();
}

async function piInit() {
  document.getElementById('piTabConfig').style.display = esAdmin() ? '' : 'none';
  document.getElementById('piTabAprobar').style.display = esAdmin() ? '' : 'none';
  await piCargarCatalogos();
  if (esAdmin()) piContarPendientes();
}

async function piContarPendientes() {
  try {
    const r = (await supaFetch('/facturas_pendientes?estado=eq.pendiente&select=id')) || [];
    document.getElementById('piPendCount').innerHTML = r.length ? `<span class="pill pend" style="height:20px;padding:0 7px;">${r.length}</span>` : '';
  } catch (_) {}
}

async function piCargarCatalogos() {
  try { piTarifasTodas = (await supaFetch('/clase_tarifas?order=tipo.asc&select=*')) || []; } catch (_) { piTarifasTodas = []; }
  piTarifas = piTarifasTodas.filter(t => t.activo);
  try {
    const f = (await supaFetch('/sedes_fiscal?select=*')) || [];
    piFiscal = Object.fromEntries(f.map(x => [x.sede, x]));
  } catch (_) { piFiscal = {}; }
}

// Al cambiar de sede
function piRefrescar() {
  if (piTab === 'xml') { piRenderCarga(); if (piF) piValidar(); }
  if (piTab === 'pagos') piCargarPagos();
}

// Recarga la lista de Gastos sin ocultar la pantalla actual
async function piRecargarGastos() {
  try {
    gastos = await supaFetchTodo(`/gastos?sede=eq.${encodeURIComponent(currentSede)}&order=fecha_clase.desc,id.desc&select=*`);
    poblarMeses(); renderGastos();
  } catch (_) {}
}


// Lectura del XML y día de pago: factura_xml.js

// ══ 2) Cargar factura ═════════════════════════════════════════════════════
async function piLeerArchivo(file) {
  if (!file) return;
  if (file.size > 2000000) { piF = null; piRenderCarga({ tipo: 'err', texto: 'El archivo es demasiado grande para ser el XML de una factura.' }); return; }
  let texto, x;
  try { texto = await file.text(); } catch (_) { piRenderCarga({ tipo: 'err', texto: 'No se pudo leer el archivo.' }); return; }
  try { x = piParseXML(texto); } catch (e) { piF = null; piRenderCarga({ tipo: 'err', texto: e.message }); return; }
  if (!piTarifas.length) await piCargarCatalogos();
  piF = { x, texto, archivo: file.name, checks: {}, inst: null, porNombre: false, clases: [], caja: false, cajaTocado: false, metodo: '', nota: '' };
  piF.clases = piClasesIniciales(x);
  piF.caja = piTodasFinde();
  piBuscarInstructor();
  piRenderCarga();
  piValidar();
}

// Propone las clases a partir del detalle del XML (el usuario las confirma)
function piClasesIniciales(x) {
  const fecha = (x.fecha || '').slice(0, 10) || piYMD(new Date());
  const filas = [];
  piTarifas.forEach(t => {
    const n = x.lineas.filter(l => piNorm(l.detalle).includes(piNorm(t.tipo)))
      .reduce((s, l) => s + (l.total > 0 && l.total % t.monto === 0 ? l.total / t.monto : l.cantidad), 0);
    if (n > 0) filas.push({ fecha, tarifaId: t.id, cantidad: n });
  });
  if (!filas.length) {
    const t = piTarifas.find(t => x.total % t.monto === 0);
    filas.push({ fecha, tarifaId: t ? t.id : '', cantidad: t ? x.total / t.monto : 1 });
  }
  return filas;
}
const piTodasFinde = () => piF.clases.length > 0 && piF.clases.every(c => c.fecha && [0, 6].includes(parseFecha(c.fecha).getDay()));

function piBuscarInstructor() {
  const ced = piF.x.emisorCedula;
  let inst = ced ? instructores.find(i => piDig(i.cedula) === ced) : null;
  piF.porNombre = false;
  if (!inst) {
    inst = instructores.find(i => !i.cedula && piNorm(i.nombre) === piNorm(piF.x.emisorNombre));
    if (inst) piF.porNombre = true;
  }
  piF.inst = inst || null;
  piF.metodo = inst ? (metodosDe(inst)[0]?.value || '') : '';
}

// ── Validaciones ──
async function piValidar() {
  const f = piF; if (!f) return;
  const x = f.x, c = {};
  const claveOk = /^\d{50}$/.test(x.clave) && x.clave.slice(9, 21) === x.emisorCedula.padStart(12, '0') && x.clave.slice(21, 41) === x.consecutivo;
  c.clave = claveOk
    ? { e: 'ok', t: 'Clave de Hacienda coherente', d: 'Coincide con la cédula del emisor y el número de la factura.' }
    : { e: 'bad', t: 'La clave de la factura no calza', d: 'La clave de 50 dígitos no coincide con el emisor o el número de factura: el XML pudo haber sido modificado.' };
  c.firma = x.firmado
    ? { e: 'ok', t: 'Firmada digitalmente', d: 'Trae la firma del emisor.' }
    : { e: 'warn', t: 'Sin firma digital', d: 'Las facturas electrónicas reales vienen firmadas. Revise que sea el XML correcto.' };
  if (x.moneda !== 'CRC') c.moneda = { e: 'bad', t: `Factura en ${x.moneda}`, d: 'Solo se aceptan facturas en colones. Regístrela manualmente en Gastos.' };

  const fis = piFiscal[currentSede];
  if (!fis || !piDig(fis.cedula_juridica)) {
    c.receptor = { e: 'warn', t: `Falta la razón social de ${currentSede}`, d: 'Un admin la registra en ⚙️ Configuración. Mientras tanto no se revisa a nombre de quién viene la factura.' };
  } else if (!x.receptorCedula) {
    c.receptor = { e: 'bad', t: 'La factura no trae receptor', d: `Debe venir a nombre de ${fis.razon_social || currentSede} (cédula jurídica ${fis.cedula_juridica}).` };
  } else if (x.receptorCedula === piDig(fis.cedula_juridica)) {
    c.receptor = { e: 'ok', t: 'A nombre de la sede correcta', d: `${x.receptorNombre} · ${x.receptorCedula}` };
  } else {
    const otra = Object.values(piFiscal).find(s => piDig(s.cedula_juridica) === x.receptorCedula);
    c.receptor = { e: 'bad', t: otra ? `Factura a nombre de ${otra.sede}` : 'Factura a nombre de otra empresa',
      d: `Viene a nombre de ${x.receptorNombre || x.receptorCedula}${otra ? ` (${otra.sede})` : ''}, pero se está cargando en ${currentSede}. `
        + (otra ? 'Cambie la sede arriba o pida' : 'Pida') + ` al instructor que la emita a nombre de ${(fis.razon_social || currentSede).replace(/\.+$/, '')}.` };
  }
  c.duplicado = { e: 'wait', t: 'Revisando si ya se cargó…' };
  c.hacienda = { e: 'wait', t: 'Consultando al emisor en Hacienda…' };
  f.checks = c;
  piRenderChecks();
  const [dup, hac] = await Promise.all([piRevisarDuplicado(x.clave, f.pend?.id), piConsultarHacienda(x.emisorCedula)]);
  if (piF !== f) return;   // se cargó otra factura mientras tanto
  c.duplicado = dup; c.hacienda = hac;
  piRenderChecks();
}

async function piRevisarDuplicado(clave, excluir) {
  try {
    const r = await supaFetch('/rpc/factura_ya_cargada', { method: 'POST', body: { p_clave: clave, p_excluir: excluir || null }, prefer: 'return=representation' });
    const d = Array.isArray(r) ? r[0] : null;
    if (!d) return { e: 'ok', t: 'No se ha cargado antes', d: 'La clave de Hacienda es única.' };
    return { e: 'bad', t: 'Esta factura ya se cargó', d: `En ${d.sede}${d.cargado_at ? ' el ' + new Date(d.cargado_at).toLocaleString('es-CR') : ''}${d.created_by ? ' por ' + d.created_by : ''}.` };
  } catch (_) {
    return { e: 'warn', t: 'No se pudo revisar si ya se cargó', d: 'Al guardar, la base igual rechaza una factura repetida.' };
  }
}

// Consulta pública de Hacienda (sin credenciales): situación tributaria del emisor
async function piConsultarHacienda(ced) {
  if (!ced) return { e: 'warn', t: 'El XML no trae la cédula del emisor' };
  const ctl = new AbortController(); const to = setTimeout(() => ctl.abort(), 8000);
  try {
    const r = await fetch('https://api.hacienda.go.cr/fe/ae?identificacion=' + encodeURIComponent(ced), { signal: ctl.signal });
    if (r.status === 404) return { e: 'warn', t: 'El emisor no aparece en Hacienda', d: `Cédula ${ced}. Revise los datos con el instructor.` };
    if (!r.ok) throw new Error(String(r.status));
    const j = await r.json();
    const estado = j?.situacion?.estado || '';
    const moroso = j?.situacion?.moroso === 'SI', omiso = j?.situacion?.omiso === 'SI';
    if (/^inscrito/i.test(estado) && !moroso && !omiso) return { e: 'ok', t: 'Emisor activo en Hacienda', d: `${j.nombre || ''} · ${estado}` };
    return { e: 'warn', t: 'Revisar al emisor en Hacienda', d: `${j.nombre || ced} · ${estado || 'sin estado'}${moroso ? ' · moroso' : ''}${omiso ? ' · omiso' : ''}` };
  } catch (_) {
    return { e: 'warn', t: 'No se pudo consultar Hacienda', d: 'El servicio no respondió. Se puede guardar igual.' };
  } finally { clearTimeout(to); }
}

// ── Cálculos ──
function piCalc() {
  const filas = piF.clases.map(c => {
    const t = piTarifas.find(t => t.id === c.tarifaId);
    const cantidad = Number(c.cantidad) || 0, tarifa = t ? Number(t.monto) : 0;
    return { fecha: c.fecha, tipo: t ? t.tipo : '', cantidad, tarifa, subtotal: cantidad * tarifa };
  });
  const esperado = filas.reduce((s, f) => s + f.subtotal, 0);
  return { filas, esperado, dif: Math.round((piF.x.total - esperado) * 100) / 100 };
}
function piPendientes() {
  const p = [];
  const checks = Object.values(piF.checks);
  checks.filter(c => c.e === 'bad').forEach(c => p.push(c.t));
  if (checks.some(c => c.e === 'wait')) p.push('Esperando las validaciones…');
  if (!piF.inst) p.push('Agregue al instructor al directorio.');
  const { filas, dif } = piCalc();
  if (!filas.length || filas.some(f => !f.tarifa || f.cantidad <= 0 || !f.fecha)) p.push('Complete las clases: fecha, tipo y cantidad.');
  if (dif !== 0 && !piF.nota.trim()) p.push('Explique por qué el monto no coincide con las tarifas.');
  if (!piF.caja && !piF.metodo) p.push('Elija a dónde se le paga, o marque pago de caja.');
  return p;
}

// ── Pantalla de carga ──
function piRenderCarga(aviso) {
  const v = document.getElementById('vista_xml');
  const avisoHtml = aviso ? `<div class="section" style="padding-bottom:0;"><div class="form-msg ${aviso.tipo}" style="font-size:15px;">${esc(aviso.texto)}</div></div>` : '';
  if (!piF) {
    v.innerHTML = `
      <div class="section"><div class="section-title">📥 Cargar factura de instructor <span class="section-note">— ${esc(currentSede)} · suba el XML de la factura electrónica: los datos se llenan solos</span></div></div>
      ${avisoHtml}
      <label class="form-card" id="piDrop" style="display:flex;flex-direction:column;align-items:center;gap:8px;text-align:center;border:2px dashed var(--brand);box-shadow:none;cursor:pointer;padding:32px 20px;margin-top:12px;">
        <div style="font-size:34px;" aria-hidden="true">📄</div>
        <div style="font-weight:600;font-size:16px;">Arrastre aquí el XML de la factura</div>
        <div class="hint">o toque para elegirlo · es el archivo .xml que el instructor recibe al emitir la factura electrónica</div>
        <input type="file" accept=".xml,text/xml,application/xml" style="display:none;" onchange="piLeerArchivo(this.files[0]); this.value='';">
        <span class="btn-primary" style="margin-top:6px;">Elegir XML</span>
      </label>
      <div class="section"><div class="hint">Al guardarla, la factura entra a «Gastos del mes» (Clases grupales) y al «Pago de la semana» que le corresponda.
        Corte: miércoles y viernes a las 10:00 a. m. Las clases de fin de semana se pagan de caja.</div></div>`;
    const drop = document.getElementById('piDrop');
    drop.ondragover = e => { e.preventDefault(); drop.style.background = 'var(--brand-tint)'; };
    drop.ondragleave = () => { drop.style.background = ''; };
    drop.ondrop = e => { e.preventDefault(); drop.style.background = ''; const fl = e.dataTransfer.files[0]; if (fl) piLeerArchivo(fl); };
    return;
  }
  const x = piF.x, pend = piF.pend;
  const PAGO_TXT = { sinpe: 'SINPE Móvil', bac: 'BAC', otro_banco: 'Otro banco' };
  const tel = pend?.telefono ? piDig(pend.telefono) : '';
  const bannerPend = pend ? `
    <div class="form-card" style="border:1.5px solid var(--blue);display:flex;flex-direction:column;gap:6px;">
      <div style="font-weight:700;font-size:16px;">📨 Enviada por el instructor el ${esc(piHora(pend.created_at))} · ${esc(pend.sede)}</div>
      <div class="hint">Revise los datos y las clases que indicó. Al aprobarla entra a Gastos y al pago que le corresponde según la hora en que la envió.</div>
      <div style="display:flex;flex-wrap:wrap;gap:6px 18px;font-size:14px;">
        ${pend.pago_numero ? `<span>Cuenta indicada: <b>${esc(PAGO_TXT[pend.pago_forma] || '')}${pend.pago_banco ? ' ' + esc(pend.pago_banco) : ''} · ${esc(pend.pago_numero)}</b></span>` : ''}
        ${tel ? `<span>Teléfono: <a href="https://wa.me/${tel.length === 8 ? '506' + tel : tel}" target="_blank" rel="noopener">${esc(pend.telefono)}</a></span>` : ''}
        ${pend.nota ? `<span>Nota: <i>${esc(pend.nota)}</i></span>` : ''}
      </div>
    </div>` : '';
  const dato = (k, val) => `<div><div class="kpi-label">${k}</div><div style="font-weight:600;font-size:15px;overflow-wrap:anywhere;">${val}</div></div>`;
  const lineas = x.lineas.slice(0, 6).map(l => `<li>${esc(l.detalle || '—')} · ${l.cantidad} · ${fmtCRC(l.total)}</li>`).join('')
    + (x.lineas.length > 6 ? `<li>… y ${x.lineas.length - 6} línea(s) más</li>` : '');
  v.innerHTML = `
    <div class="section"><div class="section-title">${pend ? '📨 Revisar factura enviada por el instructor' : '📥 Cargar factura de instructor'} <span class="section-note">— ${esc(currentSede)}</span></div></div>
    ${avisoHtml}
    ${bannerPend}
    <div style="display:flex;flex-wrap:wrap;gap:16px;align-items:flex-start;padding:0 var(--gut);">
      <div style="flex:1 1 320px;min-width:0;display:flex;flex-direction:column;gap:12px;">
        <div class="form-card" style="margin:0;display:flex;align-items:center;gap:12px;">
          <div style="flex:1;min-width:0;"><div style="font-weight:600;overflow-wrap:anywhere;">${esc(piF.archivo)}</div><div class="hint">XML leído correctamente</div></div>
          <button class="btn-ghost" onclick="piCancelar()">${pend ? '← Volver a la lista' : 'Cargar otra'}</button>
        </div>
        <div class="form-card" style="margin:0;">
          <div class="section-title" style="margin-bottom:12px;">Validaciones automáticas</div>
          <div id="piChecks"></div>
          <div class="hint" style="margin-top:12px;">El estado «Aceptada» en Hacienda se agregará en una segunda etapa (requiere las credenciales ATV de cada razón social).</div>
        </div>
      </div>
      <div style="flex:1.5 1 520px;min-width:0;display:flex;flex-direction:column;gap:12px;">
        <div class="form-card" style="margin:0;">
          <div class="section-title" style="margin-bottom:12px;">Datos de la factura</div>
          <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:14px;">
            ${dato('Emisor', `${esc(x.emisorNombre || '—')}<div class="hint" style="font-weight:400;">Cédula ${esc(x.emisorCedula || '—')}</div>`)}
            ${dato('N.º de factura', esc(x.consecutivo || '—'))}
            ${dato('Fecha', esc(x.fecha ? new Date(x.fecha).toLocaleString('es-CR') : '—'))}
            ${dato('Monto total', `<span style="font-size:20px;">${x.moneda === 'CRC' ? fmtCRC(x.total) : esc(x.moneda) + ' ' + x.total.toLocaleString('es-CR')}</span>`)}
            ${dato('A nombre de', `${esc(x.receptorNombre || '—')}<div class="hint" style="font-weight:400;">${esc(x.receptorCedula || '')}</div>`)}
          </div>
          <div class="kpi-label" style="margin-top:14px;">Detalle</div>
          <ul style="margin:4px 0 0;padding-left:18px;font-size:14px;">${lineas || '<li>—</li>'}</ul>
        </div>
        <div class="form-card" style="margin:0;" id="piInstCard"></div>
        <div class="form-card" style="margin:0;">
          <div class="section-title" style="margin-bottom:4px;">Clases que cubre esta factura</div>
          <div class="hint" style="margin-bottom:10px;">Una factura puede traer varias clases (por ejemplo, 3 clases del mismo día).</div>
          <div id="piClases"></div>
          <div id="piComparacion" style="margin-top:10px;"></div>
          <div class="f-field" id="piNotaWrap" style="margin-top:10px;display:none;">
            <label for="piNota">Motivo de la diferencia <span class="req">*</span></label>
            <textarea id="piNota" rows="2" placeholder="Ej. clase de 90 minutos autorizada por coordinación" oninput="piF.nota=this.value; piActualizar();">${esc(piF.nota)}</textarea>
          </div>
        </div>
        <div class="form-card" style="margin:0;">
          <div class="section-title" style="margin-bottom:8px;">Día de pago</div>
          <div id="piPagoInfo"></div>
          <label style="display:flex;gap:10px;align-items:flex-start;margin-top:12px;padding:12px 14px;border-radius:10px;background:var(--fill);cursor:pointer;font-size:14px;">
            <input type="checkbox" id="piCaja" ${piF.caja ? 'checked' : ''} onchange="piF.caja=this.checked; piF.cajaTocado=true; piActualizar();" style="width:20px;height:20px;margin:0;flex:none;">
            <span><b>Clase de fin de semana: se paga de caja</b><br><span class="hint">Igual entra a Gastos, pero no aparece en el pago del miércoles ni del viernes.</span></span>
          </label>
        </div>
        <div class="form-actions" style="padding:0;">
          <div class="form-msg" id="piMsg"></div>
          ${pend ? '<button class="btn-del" onclick="piRechazar()">✕ Rechazar</button>' : '<button class="btn-ghost" onclick="piCancelar()">Cancelar</button>'}
          <button class="btn-primary" id="piGuardar" onclick="piGuardar()">${pend ? '✓ Aprobar y enviar a Gastos' : '💾 Guardar y enviar a Gastos'}</button>
        </div>
      </div>
    </div>`;
  piRenderInstructor();
  piRenderClases();
  piRenderChecks();
}

function piRenderChecks() {
  const el = document.getElementById('piChecks');
  if (!el || !piF) return;
  const ICON = { ok: '✅', warn: '⚠️', bad: '⛔', wait: '⏳' };
  const COLOR = { ok: 'var(--label)', warn: 'var(--orange)', bad: 'var(--red)', wait: 'var(--sec)' };
  el.innerHTML = Object.values(piF.checks).map(c => `
    <div style="display:flex;gap:10px;margin-bottom:10px;font-size:14px;">
      <span aria-hidden="true">${ICON[c.e]}</span>
      <div><b style="color:${COLOR[c.e]};">${esc(c.t)}</b>${c.d ? `<div class="hint">${esc(c.d)}</div>` : ''}</div>
    </div>`).join('');
  piActualizar();
}

function piRenderInstructor() {
  const el = document.getElementById('piInstCard');
  if (!el) return;
  const inst = piF.inst;
  if (inst) {
    const met = metodosDe(inst);
    el.innerHTML = `
      <div class="section-title" style="margin-bottom:10px;">Instructor</div>
      <div style="display:flex;flex-wrap:wrap;gap:8px 12px;align-items:center;margin-bottom:12px;">
        <b style="font-size:16px;">${esc(inst.nombre)}</b>
        ${piF.porNombre ? '<span class="pill pend" title="El directorio no tiene su cédula; se reconoció por el nombre">Reconocido por nombre</span>' : '<span class="pill ok">En el directorio</span>'}
      </div>
      <div class="f-field">
        <label for="piMetodo">Se le paga a</label>
        ${met.length
          ? `<select id="piMetodo" onchange="piF.metodo=this.value; piActualizar();">${met.map(m => `<option value="${m.value}"${m.value === piF.metodo ? ' selected' : ''}>${esc(m.banco)} · ${esc(m.cuenta)}</option>`).join('')}</select>`
          : '<div class="pay-box">Este instructor no tiene cuenta ni SINPE en el directorio. Un admin puede agregarlos en «Gastos del mes» (✏️ junto al instructor), o marque pago de caja.</div>'}
      </div>`;
    return;
  }
  const pp = piF.pend || {};
  el.innerHTML = `
    <div class="section-title" style="margin-bottom:4px;">Instructor nuevo</div>
    <div class="hint" style="margin-bottom:12px;">La cédula ${esc(piF.x.emisorCedula || '—')} no está en el directorio. Agréguelo para saber a dónde pagarle.</div>
    <div class="form-grid">
      <div class="f-field"><label for="piNNombre">Nombre <span class="req">*</span></label><input id="piNNombre" value="${esc(piF.x.emisorNombre)}"></div>
      <div class="f-field"><label for="piNForma">Forma de pago <span class="req">*</span></label>
        <select id="piNForma" onchange="document.getElementById('piNBancoWrap').style.display=this.value==='otro_banco'?'':'none'">
          ${[['sinpe', 'SINPE Móvil'], ['bac', 'Cuenta BAC'], ['otro_banco', 'Otro banco']].map(([v, t]) => `<option value="${v}"${pp.pago_forma === v ? ' selected' : ''}>${t}</option>`).join('')}
        </select></div>
      <div class="f-field" id="piNBancoWrap" style="display:${pp.pago_forma === 'otro_banco' ? '' : 'none'};"><label for="piNBanco">Banco</label><input id="piNBanco" placeholder="Ej. BN, BCR, Popular" value="${esc(pp.pago_banco || '')}"></div>
      <div class="f-field"><label for="piNNumero">Número de cuenta o teléfono <span class="req">*</span></label><input id="piNNumero" value="${esc(pp.pago_numero || '')}"></div>
    </div>
    <div class="form-actions" style="padding:12px 0 0;">
      <div class="form-msg" id="piNMsg"></div>
      <button class="btn-ghost" id="piNBtn" onclick="piCrearInstructor()">➕ Agregar al directorio</button>
    </div>`;
}

async function piCrearInstructor() {
  const msg = document.getElementById('piNMsg');
  const nombre = document.getElementById('piNNombre').value.trim();
  const forma = document.getElementById('piNForma').value;
  const numero = document.getElementById('piNNumero').value.trim();
  const banco = document.getElementById('piNBanco').value.trim();
  msg.className = 'form-msg err';
  if (!nombre) { msg.textContent = 'Indique el nombre.'; return; }
  if (!numero) { msg.textContent = 'Indique la cuenta o el teléfono de SINPE.'; return; }
  if (forma === 'otro_banco' && !banco) { msg.textContent = 'Indique el banco.'; return; }
  const body = { nombre, cedula: piF.x.emisorCedula || null };
  if (forma === 'sinpe') body.sinpe_movil = numero;
  else if (forma === 'bac') body.cuenta_bac = numero;
  else { body.otro_banco = banco; body.cuenta_otro = numero; }
  const btn = document.getElementById('piNBtn'); btn.disabled = true;
  try {
    await supaFetch('/instructores', { method: 'POST', body });
    await cargarInstructores();
    piBuscarInstructor();
    piRenderInstructor();
    piActualizar();
  } catch (e) {
    btn.disabled = false;
    msg.textContent = /cedula/i.test(e.message) ? 'Ya existe un instructor con esa cédula (puede estar desactivado). Pida a un admin que lo revise.'
      : /duplicate|unique/i.test(e.message) ? 'Ya existe un instructor con ese nombre. Pida a un admin que le agregue la cédula en el directorio.'
      : e.message;
  }
}

function piRenderClases() {
  const el = document.getElementById('piClases');
  if (!el) return;
  if (!piTarifas.length) {
    el.innerHTML = `<div class="pay-box">No hay tarifas configuradas. ${esAdmin() ? 'Agréguelas en ⚙️ Configuración.' : 'Pida a un admin que las agregue.'}</div>`;
    return;
  }
  const opciones = sel => '<option value="">— Tipo —</option>' + piTarifas.map(t => `<option value="${t.id}"${t.id === sel ? ' selected' : ''}>${esc(t.tipo)} · ${fmtCRC(t.monto)}</option>`).join('');
  el.innerHTML = `
    <div class="g-wrap" style="margin:0;">
      <table class="g-table">
        <thead><tr><th>Fecha de la clase</th><th>Tipo de clase</th><th class="num">Cantidad</th><th class="num">Subtotal</th><th></th></tr></thead>
        <tbody>${piF.clases.map((c, i) => `
          <tr>
            <td><input type="date" value="${esc(c.fecha)}" aria-label="Fecha de la clase" style="width:150px;text-align:left;" onchange="piCambiarClase(${i},'fecha',this.value)"></td>
            <td><select aria-label="Tipo de clase" class="ui" onchange="piCambiarClase(${i},'tarifaId',this.value)">${opciones(c.tarifaId)}</select></td>
            <td class="num"><input type="number" min="1" step="1" value="${esc(c.cantidad)}" aria-label="Cantidad de clases" style="width:70px;" oninput="piCambiarClase(${i},'cantidad',this.value)"></td>
            <td class="num" id="piSub${i}"></td>
            <td class="num">${piF.clases.length > 1 ? `<button class="btn-del" title="Quitar" aria-label="Quitar fila" onclick="piQuitarClase(${i})">✕</button>` : ''}</td>
          </tr>`).join('')}
        </tbody>
      </table>
    </div>
    <button class="btn-ghost" style="margin-top:8px;" onclick="piAgregarClase()">＋ Agregar otro tipo de clase</button>`;
  piActualizar();
}
function piCambiarClase(i, campo, valor) {
  piF.clases[i][campo] = valor;
  if (campo === 'fecha' && !piF.cajaTocado) {
    piF.caja = piTodasFinde();
    const cb = document.getElementById('piCaja'); if (cb) cb.checked = piF.caja;
  }
  piActualizar();
}
function piAgregarClase() {
  const ult = piF.clases[piF.clases.length - 1];
  piF.clases.push({ fecha: ult ? ult.fecha : piYMD(new Date()), tarifaId: '', cantidad: 1 });
  piRenderClases();
}
function piQuitarClase(i) { piF.clases.splice(i, 1); piRenderClases(); }

// Refresca lo calculado sin redibujar los campos (no se pierde el foco)
function piActualizar() {
  if (!piF) return;
  const { filas, esperado, dif } = piCalc();
  filas.forEach((f, i) => { const td = document.getElementById('piSub' + i); if (td) td.textContent = f.tarifa ? fmtCRC(f.subtotal) : '—'; });
  const comp = document.getElementById('piComparacion');
  if (comp) {
    const ok = dif === 0;
    comp.innerHTML = `
      <div style="display:flex;flex-wrap:wrap;gap:12px 24px;align-items:center;padding:12px 16px;border-radius:12px;background:${ok ? 'var(--green-tint)' : 'var(--orange-tint)'};">
        <div><div class="kpi-label">Según tarifas</div><div style="font-size:20px;font-weight:700;">${fmtCRC(esperado)}</div></div>
        <div><div class="kpi-label">Según factura</div><div style="font-size:20px;font-weight:700;">${fmtCRC(piF.x.total)}</div></div>
        ${ok ? '<span class="pill ok">Coincide</span>' : `<span class="pill pend">Diferencia ${dif > 0 ? '+' : '−'}${fmtCRC(Math.abs(dif))}</span>`}
      </div>`;
    document.getElementById('piNotaWrap').style.display = ok ? 'none' : '';
  }
  const info = document.getElementById('piPagoInfo');
  if (info) {
    const d = piF.pend ? piDiaPagoPara(piF.pend.created_at) : piDiaPagoEstimado();
    info.innerHTML = piF.caja
      ? '<div style="font-size:20px;font-weight:700;">Pago de caja</div><div class="hint">Clase de fin de semana: no entra al pago del miércoles ni del viernes.</div>'
      : `<div style="display:flex;flex-wrap:wrap;gap:8px 12px;align-items:center;"><span style="font-size:20px;font-weight:700;">${d ? piFechaLarga(d) : '—'}</span><span class="pill info">Transferencia</span></div>
         <div class="hint" style="margin-top:4px;">${piF.pend
           ? `Según la hora en que el instructor la envió (${esc(piHora(piF.pend.created_at))}).${d && d < piSumarDias(piAhoraCR(), 0) ? ' <b style="color:var(--orange);">Ese día ya pasó: quedará como atrasada.</b>' : ''}`
           : 'Si se guarda ahora. El día exacto lo fija el sistema con la hora del servidor (corte: miércoles y viernes a las 10:00 a. m.).'}</div>`;
  }
  const pend = piPendientes();
  const btn = document.getElementById('piGuardar');
  if (btn && !piF.guardando) btn.disabled = pend.length > 0;
  const msg = document.getElementById('piMsg');
  if (msg && !piF.guardando) { msg.className = 'form-msg'; msg.textContent = pend[0] || ''; }
}

function piCancelar() {
  const eraPend = !!piF?.pend;
  piF = null;
  if (eraPend) piMostrar('aprobar'); else piRenderCarga();
}

async function piGuardar() {
  const f = piF;
  const pend = piPendientes();
  const msg = document.getElementById('piMsg');
  if (pend.length) { msg.className = 'form-msg err'; msg.textContent = pend[0]; return; }
  const x = f.x, { filas, esperado, dif } = piCalc();
  const fechaClase = filas.map(r => r.fecha).sort()[0];
  const d = parseFecha(fechaClase);
  const m = f.caja ? null : metodosDe(f.inst).find(mm => mm.value === f.metodo);
  const payload = {
    sede: currentSede,
    categoria: 'clases_grupales',
    fecha_clase: fechaClase,
    mes: mesEtiqueta(d),
    mes_orden: mesOrden(d),
    emisor: x.emisorNombre || f.inst.nombre,
    instructor_id: f.inst.id,
    documento_cobro: 'Factura electrónica',
    numero_factura: x.consecutivo || null,
    monto: x.total,
    metodo_pago: f.caja ? 'caja' : f.metodo,
    banco_pago: f.caja ? 'Pago de caja' : (m ? m.banco : null),
    cuenta_pago: f.caja ? null : (m ? m.cuenta : null),
    created_by: currentEmail || null,
    origen: 'xml',
    clave_hacienda: x.clave,
    emisor_cedula: x.emisorCedula || null,
    detalle_clases: filas,
    monto_esperado: esperado,
    nota_diferencia: dif !== 0 ? f.nota.trim() : null,
    pago_tipo: f.caja ? 'caja' : 'transferencia',
    factura_pendiente_id: f.pend ? f.pend.id : null,
  };
  const btn = document.getElementById('piGuardar');
  f.guardando = true; btn.disabled = true; btn.textContent = 'Guardando…';
  try {
    // Reconocido por nombre: un admin aprovecha para guardarle la cédula en el directorio
    if (f.porNombre && esAdmin() && x.emisorCedula) {
      try { await supaFetch(`/instructores?id=eq.${encodeURIComponent(f.inst.id)}`, { method: 'PATCH', body: { cedula: x.emisorCedula } }); await cargarInstructores(); } catch (_) {}
    }
    const r = await supaFetch('/gastos', { method: 'POST', body: payload, prefer: 'return=representation' });
    const g = Array.isArray(r) ? r[0] : r;
    let extra = '';
    try { await supaFetch('/gastos_xml', { method: 'POST', body: { gasto_id: g.id, xml: f.texto, nombre_archivo: f.archivo } }); }
    catch (_) { extra = ' (No se pudo guardar una copia del XML.)'; }
    const cuando = g.pago_tipo === 'caja' ? 'Se paga de caja.' : g.dia_pago ? `Se paga el ${piFechaLarga(parseFecha(g.dia_pago))}.` : '';
    piF = null;
    const texto = `✅ Factura de ${payload.emisor} por ${fmtCRC(payload.monto)} ${f.pend ? 'aprobada y enviada a' : 'guardada en'} Gastos. ${cuando}${extra}`;
    if (f.pend) { piAvisoAprobar = { tipo: 'ok', texto }; piMostrar('aprobar'); }
    else piRenderCarga({ tipo: 'ok', texto });
    piRecargarGastos();
  } catch (e) {
    f.guardando = false; btn.disabled = false; btn.textContent = f.pend ? '✓ Aprobar y enviar a Gastos' : '💾 Guardar y enviar a Gastos';
    msg.className = 'form-msg err';
    msg.textContent = /clave_hacienda|duplicate|unique/i.test(e.message) ? 'Esta factura ya se cargó antes.'
      : /column|origen|pago_tipo/i.test(e.message) ? 'Falta correr pagos_instructores.sql en Supabase.'
      : 'No se pudo guardar: ' + e.message;
  }
}

// ══ 2b) Por aprobar: facturas que envió el instructor desde /factura (solo admin) ══
let piAvisoAprobar = null;

async function piCargarPendientes() {
  const v = document.getElementById('vista_aprobar');
  v.innerHTML = '<div class="loading" style="display:block;"><div class="spinner"></div><div>Cargando facturas por aprobar…</div></div>';
  try {
    piPorAprobar = (await supaFetch('/facturas_pendientes?estado=eq.pendiente&order=created_at.asc'
      + '&select=id,sede,numero_factura,emisor_nombre,emisor_cedula,monto,clases,pago_forma,pago_numero,telefono,nota,created_at')) || [];
  } catch (e) {
    v.innerHTML = `<div class="empty-state" style="display:block;">⚠️ No se pudieron cargar: ${esc(e.message)}`
      + (/facturas_pendientes|relation|schema/i.test(e.message) ? '<br>¿Ya se corrió pagos_instructores.sql en Supabase?' : '') + '</div>';
    return;
  }
  piContarPendientes();
  const aviso = piAvisoAprobar; piAvisoAprobar = null;
  const enlace = location.origin + '/factura';
  const hoy = piSumarDias(piAhoraCR(), 0);
  const filas = piPorAprobar.map((p, i) => {
    const dia = piDiaPagoPara(p.created_at);
    const clases = (Array.isArray(p.clases) ? p.clases : []).map(c => `${c.cantidad} ${c.tipo} (${piFechaCorta(c.fecha)})`).join(' · ');
    return `<tr>
      <td>${esc(piHora(p.created_at))}</td>
      <td>${esc(p.sede)}</td>
      <td><b>${esc(p.emisor_nombre || '—')}</b><br><span class="hint">${esc(p.emisor_cedula || '')}</span></td>
      <td>…${esc(String(p.numero_factura || '').slice(-6))}</td>
      <td>${esc(clases || '—')}${p.nota ? `<br><span class="hint">Nota: ${esc(p.nota)}</span>` : ''}</td>
      <td class="num"><b>${fmtCRC(p.monto)}</b></td>
      <td>${dia ? esc(piFechaLarga(dia)) : '—'}${dia && dia < hoy ? '<br><span class="pill pend">Ya pasó</span>' : ''}</td>
      <td class="num"><button class="btn-primary" onclick="piRevisarPendiente(${i})">Revisar</button></td>
    </tr>`;
  }).join('');
  v.innerHTML = `
    <div class="section"><div class="section-title">📨 Facturas por aprobar <span class="section-note">— enviadas por los instructores desde la página pública · todas las sedes</span></div></div>
    ${aviso ? `<div class="section" style="padding-top:0;"><div class="form-msg ${aviso.tipo}" style="font-size:15px;">${esc(aviso.texto)}</div></div>` : ''}
    <div class="form-card" style="display:flex;flex-wrap:wrap;gap:10px;align-items:center;">
      <div style="flex:1 1 280px;"><b>Enlace para los instructores</b><div class="hint">Mándelo por WhatsApp: ahí suben el XML de su factura, sin usuario ni contraseña.</div></div>
      <code style="font-size:14px;padding:8px 12px;border-radius:8px;background:var(--fill);overflow-wrap:anywhere;">${esc(enlace)}</code>
      <button class="btn-ghost" onclick="piCopiarEnlace(this)">Copiar</button>
    </div>
    <div class="section"><div class="g-wrap" style="margin:0;">
      <table class="g-table">
        <thead><tr><th>Recibida</th><th>Sede</th><th>Instructor</th><th>Factura</th><th>Clases que indicó</th><th class="num">Monto</th><th>Se pagaría</th><th></th></tr></thead>
        <tbody>${filas || '<tr><td colspan="8" class="g-empty">No hay facturas esperando aprobación.</td></tr>'}</tbody>
      </table>
    </div></div>`;
}

function piCopiarEnlace(btn) {
  const enlace = location.origin + '/factura';
  (navigator.clipboard ? navigator.clipboard.writeText(enlace) : Promise.reject())
    .then(() => { btn.textContent = '✓ Copiado'; }, () => { prompt('Copie el enlace:', enlace); });
}

// Abre la factura en la pantalla de revisión (la misma de «Cargar factura XML»)
async function piRevisarPendiente(i) {
  const resumen = piPorAprobar[i]; if (!resumen) return;
  let p;
  try { p = ((await supaFetch(`/facturas_pendientes?id=eq.${encodeURIComponent(resumen.id)}&select=*`)) || [])[0]; }
  catch (e) { alert('No se pudo abrir: ' + e.message); return; }
  if (!p || p.estado !== 'pendiente') { alert('Esta factura ya fue revisada.'); piCargarPendientes(); return; }
  let x;
  try { x = piParseXML(p.xml); } catch (e) { alert('El XML guardado no se pudo leer: ' + e.message); return; }
  // La factura se revisa en su sede
  if (p.sede !== currentSede && SEDES.includes(p.sede)) {
    currentSede = p.sede;
    const sel = document.getElementById('sedeSelector'); if (sel) sel.value = p.sede;
    piRecargarGastos();
  }
  if (!piTarifas.length) await piCargarCatalogos();
  piF = { x, texto: p.xml, archivo: p.nombre_archivo || `factura_${p.numero_factura || ''}.xml`, pend: p,
          checks: {}, inst: null, porNombre: false, clases: [], caja: false, cajaTocado: false, metodo: '', nota: '' };
  const clases = (Array.isArray(p.clases) ? p.clases : []).map(c => ({
    fecha: c.fecha, cantidad: c.cantidad, tarifaId: piTarifas.find(t => piNorm(t.tipo) === piNorm(c.tipo))?.id || '' }));
  piF.clases = clases.length ? clases : piClasesIniciales(x);
  piF.caja = piTodasFinde();
  piBuscarInstructor();
  piTab = 'xml';
  document.querySelectorAll('#piTabs .tab').forEach(b => b.classList.toggle('active', b.dataset.tab === 'xml'));
  ['xml', 'aprobar', 'pagos', 'config'].forEach(t => { document.getElementById('vista_' + t).style.display = t === 'xml' ? '' : 'none'; });
  document.getElementById('vistaGastos').style.display = 'none';
  piRenderCarga();
  piValidar();
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

async function piRechazar() {
  const p = piF?.pend; if (!p) return;
  const motivo = prompt(`¿Por qué se rechaza la factura de ${p.emisor_nombre || 'este instructor'}?\n(Avísele al instructor: puede corregirla y volver a enviarla.)`);
  if (motivo === null) return;
  if (!motivo.trim()) { alert('Escriba el motivo del rechazo.'); return; }
  try {
    await supaFetch(`/facturas_pendientes?id=eq.${encodeURIComponent(p.id)}&estado=eq.pendiente`, { method: 'PATCH',
      body: { estado: 'rechazada', motivo_rechazo: motivo.trim(), revisado_por: currentEmail || null, revisado_at: new Date().toISOString() } });
    piF = null;
    piAvisoAprobar = { tipo: 'ok', texto: `Factura de ${p.emisor_nombre || 'el instructor'} rechazada.` };
    piMostrar('aprobar');
  } catch (e) { alert('No se pudo rechazar: ' + e.message); }
}

// ══ 3) Pago de la semana ══════════════════════════════════════════════════
const PI_COLS = 'id,sede,fecha_clase,emisor,emisor_cedula,instructor_id,numero_factura,monto,monto_esperado,nota_diferencia,banco_pago,cuenta_pago,metodo_pago,pago_tipo,dia_pago,cargado_at,pagado_at,pagado_por,detalle_clases';

function piSemanaInicial() {
  const hoy = piAhoraCR();
  piSemana = piLunes(hoy);
  const dow = hoy.getDay();   // 0 domingo … 6 sábado
  piDia = dow === 0 || dow === 6 ? 'caja' : (dow === 4 || dow === 5 ? 'vie' : 'mie');
}
function piMoverSemana(n) { piSemana = piSumarDias(piSemana, n); piAbiertos.clear(); piCargarPagos(); }
function piSemanaHoy() { piSemanaInicial(); piAbiertos.clear(); piCargarPagos(); }
function piElegirDia(d) { piDia = d; piAbiertos.clear(); piRenderPagos(); }

async function piTraerPagos(sedes, lun, dom) {
  const filtroSede = sedes.length === 1
    ? `sede=eq.${encodeURIComponent(sedes[0])}`
    : `sede=in.(${sedes.map(s => encodeURIComponent('"' + s + '"')).join(',')})`;
  return supaFetchTodo(`/gastos?origen=eq.xml&${filtroSede}`
    + `&or=(and(dia_pago.gte.${lun},dia_pago.lte.${dom}),and(pago_tipo.eq.caja,fecha_clase.gte.${lun},fecha_clase.lte.${dom}))`
    + `&select=${PI_COLS}&order=emisor.asc,id.asc`);
}

async function piCargarPagos() {
  if (!piSemana) piSemanaInicial();
  const v = document.getElementById('vista_pagos');
  v.innerHTML = '<div class="loading" style="display:block;"><div class="spinner"></div><div>Cargando pagos…</div></div>';
  const lun = piYMD(piSemana), dom = piYMD(piSumarDias(piSemana, 6));
  try {
    piPagos = await piTraerPagos([currentSede], lun, dom);
    piAtrasados = (await supaFetch(`/gastos?origen=eq.xml&sede=eq.${encodeURIComponent(currentSede)}&pagado_at=is.null&dia_pago=lt.${lun}&select=id,monto,dia_pago`)) || [];
    piRenderPagos();
  } catch (e) {
    v.innerHTML = `<div class="empty-state" style="display:block;">⚠️ No se pudieron cargar los pagos: ${esc(e.message)}`
      + (/column|origen|dia_pago/i.test(e.message) ? '<br>¿Ya se corrió pagos_instructores.sql en Supabase?' : '') + '</div>';
  }
}

function piDiaDe(g) {
  if (g.pago_tipo === 'caja') return 'caja';
  if (!g.dia_pago) return null;
  return parseFecha(g.dia_pago).getDay() === 5 ? 'vie' : 'mie';
}

// Un renglón por instructor (y por cuenta, si se le pagó a cuentas distintas)
function piAgrupar(rows) {
  const map = new Map();
  rows.forEach(g => {
    const key = (g.instructor_id || g.emisor_cedula || g.emisor) + '|' + (g.cuenta_pago || '');
    if (!map.has(key)) {
      const inst = instructores.find(i => i.id === g.instructor_id);
      map.set(key, { nombre: inst?.nombre || g.emisor, cedula: inst?.cedula || g.emisor_cedula || '', banco: g.banco_pago || '', cuenta: g.cuenta_pago || '', rows: [], total: 0 });
    }
    const gr = map.get(key); gr.rows.push(g); gr.total += Number(g.monto) || 0;
  });
  return [...map.values()].sort((a, b) => a.nombre.localeCompare(b.nombre, 'es'));
}
function piResumenClases(rows) {
  const t = {};
  rows.forEach(g => (Array.isArray(g.detalle_clases) ? g.detalle_clases : []).forEach(c => { t[c.tipo] = (t[c.tipo] || 0) + (Number(c.cantidad) || 0); }));
  return Object.entries(t).map(([k, n]) => `${n} ${k}`).join(' · ') || '—';
}
function piEstado(gr, caja) {
  if (caja) return { txt: 'Caja', pill: '' };
  const pag = gr.rows.filter(r => r.pagado_at);
  if (pag.length === gr.rows.length) {
    const ult = pag.map(r => r.pagado_at).sort().pop();
    return { txt: 'Pagado ' + piHora(ult), pill: 'ok', pagado: true };
  }
  if (pag.length) return { txt: `Parcial ${pag.length}/${gr.rows.length}`, pill: 'pend' };
  return { txt: 'Pendiente', pill: 'pend' };
}
function piEtiquetaDia(d) {
  if (d === 'caja') return `Fin de semana (caja) · ${piFechaCorta(piYMD(piSumarDias(piSemana, 5)))} y ${piFechaCorta(piYMD(piSumarDias(piSemana, 6)))}`;
  return piFechaLarga(piSumarDias(piSemana, d === 'vie' ? 4 : 2));
}

function piRenderPagos() {
  const v = document.getElementById('vista_pagos');
  const porDia = { mie: [], vie: [], caja: [] };
  piPagos.forEach(g => { const d = piDiaDe(g); if (d) porDia[d].push(g); });
  const rows = porDia[piDia];
  const caja = piDia === 'caja';
  piGrupos = piAgrupar(rows);
  const total = rows.reduce((s, g) => s + Number(g.monto || 0), 0);
  const pagado = caja ? total : rows.filter(g => g.pagado_at).reduce((s, g) => s + Number(g.monto || 0), 0);
  const conNota = rows.filter(g => g.nota_diferencia).length;
  const dom = piSumarDias(piSemana, 6);
  const seg = (d, titulo) => {
    const rs = porDia[d], tot = rs.reduce((s, g) => s + Number(g.monto || 0), 0), n = piAgrupar(rs).length;
    return `<button class="tab${d === piDia ? ' active' : ''}" style="flex-direction:column;min-height:58px;white-space:normal;padding:6px 10px;" onclick="piElegirDia('${d}')">
      <span>${titulo}</span><span style="font-weight:400;font-size:12px;color:var(--sec);">${fmtCRC(tot)} · ${n} instructor${n === 1 ? '' : 'es'}</span></button>`;
  };
  const atr = piAtrasados.length
    ? `<div class="section" style="padding-top:8px;padding-bottom:0;"><div class="pay-box" style="border-color:var(--orange);">⚠️ Hay <b>${piAtrasados.length}</b> factura(s) de semanas anteriores sin marcar como pagadas (${fmtCRC(piAtrasados.reduce((s, g) => s + Number(g.monto || 0), 0))}). Use ‹ para revisarlas.</div></div>`
    : '';
  const acciones = !caja && piPuedePagar();
  const cuerpo = piGrupos.length ? piGrupos.map((gr, i) => {
    const est = piEstado(gr, caja);
    const nota = gr.rows.some(r => r.nota_diferencia) ? ` <span class="pill pend" title="${esc(gr.rows.filter(r => r.nota_diferencia).map(r => r.nota_diferencia).join(' · '))}">Con nota</span>` : '';
    const abierto = piAbiertos.has(i);
    const detalle = abierto ? `<tr><td colspan="${acciones ? 7 : 6}" style="background:var(--fill);font-size:13px;">
        ${gr.rows.map(r => `<div style="display:flex;flex-wrap:wrap;gap:4px 16px;align-items:center;padding:4px 0;">
          <span>Factura …${esc(String(r.numero_factura || '').slice(-6))}</span>
          <span>Clase ${esc(piFechaCorta(r.fecha_clase))}</span>
          <span>${esc(piResumenClases([r]))}</span>
          <b>${fmtCRC(r.monto)}</b>
          ${r.nota_diferencia ? `<span style="color:var(--orange);">Nota: ${esc(r.nota_diferencia)}</span>` : ''}
          <span class="hint">Cargada ${esc(piHora(r.cargado_at))}${r.pagado_at ? ` · pagada ${esc(piHora(r.pagado_at))}${r.pagado_por ? ' por ' + esc(r.pagado_por) : ''}` : ''}</span>
          <button class="btn-edit" onclick="piDescargarXml('${r.id}')">⬇️ XML</button>
        </div>`).join('')}
      </td></tr>` : '';
    return `<tr>
      <td><button class="btn-edit" aria-label="${abierto ? 'Ocultar' : 'Ver'} facturas" onclick="piToggle(${i})">${abierto ? '▾' : '▸'}</button> <b>${esc(gr.nombre)}</b>${gr.cedula ? `<br><span class="hint">${esc(gr.cedula)}</span>` : ''}</td>
      <td>${esc(gr.banco || '—')}${gr.cuenta ? `<br><span style="font-size:12px;color:var(--muted);">${esc(gr.cuenta)}</span>` : ''}</td>
      <td class="num">${gr.rows.length}</td>
      <td>${esc(piResumenClases(gr.rows))}</td>
      <td class="num"><b>${fmtCRC(gr.total)}</b></td>
      <td><span class="pill ${est.pill}">${esc(est.txt)}</span>${nota}</td>
      ${acciones ? `<td class="num" style="white-space:nowrap;">${est.pagado
        ? `<button class="btn-ghost" onclick="piMarcar(${i}, false)">Desmarcar</button>`
        : `<button class="btn-ok" onclick="piMarcar(${i}, true)">✓ Marcar pagado</button>`}</td>` : ''}
    </tr>${detalle}`;
  }).join('') : `<tr><td colspan="${acciones ? 7 : 6}" class="g-empty">No hay facturas para este día de pago.</td></tr>`;

  v.innerHTML = `
    <div class="section" style="display:flex;flex-wrap:wrap;gap:10px;align-items:center;">
      <div class="section-title" style="margin:0;">💸 Pago de la semana <span class="section-note">— ${esc(currentSede)} · del lunes ${piSemana.getDate()} al domingo ${dom.getDate()} de ${dom.toLocaleDateString('es-CR', { month: 'long' })}</span></div>
      <span style="margin-left:auto;display:flex;gap:6px;">
        <button class="btn-ghost" onclick="piMoverSemana(-7)" aria-label="Semana anterior">‹</button>
        <button class="btn-ghost" onclick="piSemanaHoy()">Esta semana</button>
        <button class="btn-ghost" onclick="piMoverSemana(7)" aria-label="Semana siguiente">›</button>
      </span>
    </div>
    <div class="tabs" style="display:grid;grid-template-columns:repeat(3,minmax(0,1fr));margin-top:0;">
      ${seg('mie', 'Miércoles ' + piSumarDias(piSemana, 2).getDate())}
      ${seg('vie', 'Viernes ' + piSumarDias(piSemana, 4).getDate())}
      ${seg('caja', 'Fin de semana · caja')}
    </div>
    ${atr}
    <div class="section" style="padding-bottom:0;"><div class="hint">${caja
      ? 'Clases de sábado y domingo: se pagan de caja. Aquí solo quedan registradas.'
      : `Corte: ${piDia === 'mie' ? 'miércoles' : 'viernes'} a las 10:00 a. m. Lo que se carga después pasa al siguiente día de pago.`}</div></div>
    <div class="kpi-row">
      <div class="kpi"><div class="kpi-label">Total ${esc(piEtiquetaDia(piDia))}</div><div class="kpi-value">${fmtCRC(total)}</div></div>
      <div class="kpi green"><div class="kpi-label">${caja ? 'Pagado de caja' : 'Pagado'}</div><div class="kpi-value">${fmtCRC(pagado)}</div></div>
      <div class="kpi orange"><div class="kpi-label">Pendiente</div><div class="kpi-value">${fmtCRC(total - pagado)}</div></div>
      <div class="kpi"><div class="kpi-label">Facturas</div><div class="kpi-value">${rows.length}</div><div class="kpi-sub">${conNota ? conNota + ' con diferencia de monto' : 'todas calzan con la tarifa'}</div></div>
    </div>
    <div class="section"><div class="g-wrap" style="margin:0;">
      <table class="g-table">
        <thead><tr><th>Instructor</th><th>Se le paga a</th><th class="num">Facturas</th><th>Clases</th><th class="num">Total</th><th>Estado</th>${acciones ? '<th></th>' : ''}</tr></thead>
        <tbody>${cuerpo}
          ${piGrupos.length ? `<tr class="cat-total"><td colspan="4">Total</td><td class="num">${fmtCRC(total)}</td><td colspan="${acciones ? 2 : 1}"></td></tr>` : ''}
        </tbody>
      </table>
    </div></div>
    <div class="form-actions" style="padding:0 var(--gut) 24px;">
      <div class="hint" style="margin-right:auto;">El Excel trae una hoja por sede, solo con lo necesario para pagar: instructor, cédula, cuenta o SINPE y monto.</div>
      <button class="btn-primary" onclick="piExcel()">⬇️ Excel de pagos por sede</button>
    </div>`;
}

function piToggle(i) { if (piAbiertos.has(i)) piAbiertos.delete(i); else piAbiertos.add(i); piRenderPagos(); }

async function piMarcar(i, pagado) {
  const gr = piGrupos[i]; if (!gr) return;
  const ids = gr.rows.filter(r => pagado ? !r.pagado_at : true).map(r => r.id);
  if (!ids.length) return;
  const monto = gr.rows.filter(r => ids.includes(r.id)).reduce((s, r) => s + Number(r.monto || 0), 0);
  if (!confirm(pagado ? `¿Marcar como pagado a ${gr.nombre} por ${fmtCRC(monto)}?` : `¿Volver a dejar pendiente el pago de ${gr.nombre}?`)) return;
  try {
    await supaFetch('/rpc/marcar_pago_instructor', { method: 'POST', body: { p_ids: ids, p_pagado: pagado }, prefer: 'return=representation' });
    await piCargarPagos();
    piRecargarGastos();
  } catch (e) { alert('No se pudo actualizar: ' + e.message); }
}

async function piDescargarXml(id) {
  try {
    const r = await supaFetch(`/gastos_xml?gasto_id=eq.${encodeURIComponent(id)}&select=xml,nombre_archivo`);
    if (!r || !r.length) { alert('No hay copia del XML de esta factura.'); return; }
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([r[0].xml], { type: 'application/xml' }));
    a.download = r[0].nombre_archivo || 'factura.xml';
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 2000);
  } catch (e) { alert('No se pudo descargar: ' + e.message); }
}

// Excel de pagos: una hoja por sede, solo lo necesario para pagar
async function piExcel() {
  const sedes = esAdmin() ? SEDES : (currentSedes.length ? currentSedes : [currentSede]);
  const lun = piYMD(piSemana), dom = piYMD(piSumarDias(piSemana, 6));
  let rows;
  try { rows = (await piTraerPagos(sedes, lun, dom)).filter(g => piDiaDe(g) === piDia); }
  catch (e) { alert('No se pudieron traer los pagos: ' + e.message); return; }
  const etiqueta = piEtiquetaDia(piDia);
  if (!rows.length) { alert(`No hay pagos para ${etiqueta}.`); return; }
  const caja = piDia === 'caja';
  const wb = XLSX.utils.book_new();
  sedes.forEach(sede => {
    const rs = rows.filter(g => g.sede === sede);
    if (!rs.length) return;
    const grupos = piAgrupar(rs);
    const fis = piFiscal[sede];
    const aoa = [
      [`Pago a instructores — ${sede} — ${etiqueta}`],
      [fis?.razon_social ? `${fis.razon_social}${fis.cedula_juridica ? ' · ' + fis.cedula_juridica : ''}` : ''],
      [`Generado: ${new Date().toLocaleString('es-CR')}`],
      [],
      ['Instructor', 'Cédula', 'Forma de pago', 'Cuenta / SINPE', 'Facturas', 'Monto', 'Estado'],
    ];
    const filasMonto = [];
    grupos.forEach(gr => {
      aoa.push([gr.nombre, gr.cedula, gr.banco, gr.cuenta, gr.rows.length, Math.round(gr.total), piEstado(gr, caja).txt]);
      filasMonto.push(aoa.length - 1);
    });
    aoa.push(['TOTAL', '', '', '', rs.length, Math.round(grupos.reduce((s, g) => s + g.total, 0)), '']);
    filasMonto.push(aoa.length - 1);
    const ws = XLSX.utils.aoa_to_sheet(aoa);
    ws['!cols'] = [{ wch: 30 }, { wch: 14 }, { wch: 16 }, { wch: 28 }, { wch: 9 }, { wch: 14 }, { wch: 20 }];
    filasMonto.forEach(r => { const ref = XLSX.utils.encode_cell({ r, c: 5 }); if (ws[ref]) ws[ref].z = '#,##0'; });
    XLSX.utils.book_append_sheet(wb, ws, sede.replace(/[\\/?*[\]:]/g, '').slice(0, 31));
  });
  const fechaArchivo = caja ? piYMD(piSumarDias(piSemana, 5)) : piYMD(piSumarDias(piSemana, piDia === 'vie' ? 4 : 2));
  XLSX.writeFile(wb, `pago_instructores_${caja ? 'caja' : piDia === 'vie' ? 'viernes' : 'miercoles'}_${fechaArchivo}.xlsx`);
}

// ══ 4) Configuración (solo admin) ══════════════════════════════════════════
async function piCargarConfig() {
  if (!esAdmin()) return;
  await piCargarCatalogos();
  piRenderConfig();
}

function piRenderConfig(aviso) {
  const v = document.getElementById('vista_config');
  const fila = (t, i) => `<tr>
      <td><input id="piTTipo${i}" value="${esc(t.tipo)}" aria-label="Tipo de clase" style="width:100%;max-width:220px;text-align:left;"></td>
      <td class="num"><input id="piTMonto${i}" type="number" min="1" step="1" value="${esc(t.monto)}" aria-label="Tarifa" style="width:110px;"></td>
      <td class="num" style="white-space:nowrap;"><button class="btn-edit" onclick="piGuardarTarifa('${t.id}', ${i})">💾 Guardar</button>
        <button class="btn-del" onclick="piQuitarTarifa('${t.id}')">Quitar</button></td></tr>`;
  v.innerHTML = `
    <div class="section"><div class="section-title">⚙️ Configuración <span class="section-note">— solo administradores · se llena una vez</span></div></div>
    ${aviso ? `<div class="section" style="padding-top:0;"><div class="form-msg ${aviso.tipo}">${esc(aviso.texto)}</div></div>` : ''}
    <div class="form-card">
      <div class="section-title" style="margin-bottom:4px;">Razón social por sede</div>
      <div class="hint" style="margin-bottom:12px;">Cada factura debe venir a nombre de la razón social de la sede donde se carga.</div>
      <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:14px;">
        ${SEDES.map((s, i) => `<div style="border:.5px solid var(--sep);border-radius:12px;padding:14px;display:flex;flex-direction:column;gap:8px;">
          <b>${esc(s)}</b>
          <div class="f-field"><label for="piRS${i}">Razón social</label><input id="piRS${i}" value="${esc(piFiscal[s]?.razon_social || '')}"></div>
          <div class="f-field"><label for="piCJ${i}">Cédula jurídica</label><input id="piCJ${i}" value="${esc(piFiscal[s]?.cedula_juridica || '')}" placeholder="3-101-XXXXXX" inputmode="numeric"></div>
        </div>`).join('')}
      </div>
      <div class="form-actions" style="padding:12px 0 0;"><button class="btn-primary" onclick="piGuardarFiscal()">💾 Guardar razones sociales</button></div>
    </div>
    <div class="form-card">
      <div class="section-title" style="margin-bottom:4px;">Tarifas por tipo de clase</div>
      <div class="hint" style="margin-bottom:12px;">Un cambio de tarifa solo afecta las facturas que se carguen después.</div>
      <div class="g-wrap" style="margin:0;"><table class="g-table">
        <thead><tr><th>Tipo de clase</th><th class="num">Tarifa por clase (₡)</th><th></th></tr></thead>
        <tbody>${piTarifas.map(fila).join('')}
          <tr><td><input id="piTTipoN" placeholder="Nuevo tipo (ej. Spinning)" aria-label="Nuevo tipo de clase" style="width:100%;max-width:220px;text-align:left;"></td>
            <td class="num"><input id="piTMontoN" type="number" min="1" step="1" placeholder="0" aria-label="Tarifa del nuevo tipo" style="width:110px;"></td>
            <td class="num"><button class="btn-ok" onclick="piAgregarTarifa()">＋ Agregar</button></td></tr>
        </tbody></table></div>
    </div>
    <div class="form-card">
      <div class="section-title" style="margin-bottom:4px;">Cédula de los instructores</div>
      <div class="hint" style="margin-bottom:12px;">Con la cédula se reconoce al instructor en el XML. Si falta, se busca por nombre y se completa sola la primera vez que un admin carga su factura.</div>
      <div class="g-wrap" style="margin:0;"><table class="g-table">
        <thead><tr><th>Instructor</th><th>Cédula</th><th></th></tr></thead>
        <tbody>${instructores.map((ins, i) => `<tr><td>${esc(ins.nombre)}</td>
          <td><input id="piIC${i}" value="${esc(ins.cedula || '')}" inputmode="numeric" aria-label="Cédula de ${esc(ins.nombre)}" style="width:150px;text-align:left;"></td>
          <td class="num"><button class="btn-edit" onclick="piGuardarCedula('${ins.id}', ${i})">💾 Guardar</button></td></tr>`).join('')
          || '<tr><td colspan="3" class="g-empty">No hay instructores en el directorio.</td></tr>'}
        </tbody></table></div>
    </div>
    <div class="section"><div class="hint">Cortes de pago (fijos): miércoles y viernes a las 10:00 a. m., hora de Costa Rica. Sábado y domingo se pagan de caja.</div></div>`;
}

async function piGuardarFiscal() {
  const body = SEDES.map((s, i) => ({
    sede: s,
    razon_social: document.getElementById('piRS' + i).value.trim() || null,
    cedula_juridica: piDig(document.getElementById('piCJ' + i).value) || null,
    updated_at: new Date().toISOString(),
    updated_by: currentEmail || null,
  }));
  try {
    await supaFetch('/sedes_fiscal', { method: 'POST', body, prefer: 'resolution=merge-duplicates,return=minimal' });
    await piCargarCatalogos(); piRenderConfig({ tipo: 'ok', texto: '✅ Razones sociales guardadas.' });
  } catch (e) { piRenderConfig({ tipo: 'err', texto: 'No se pudo guardar: ' + e.message }); }
}

async function piGuardarTarifa(id, i) {
  const tipo = document.getElementById('piTTipo' + i).value.trim();
  const monto = Number(document.getElementById('piTMonto' + i).value);
  if (!tipo || !(monto > 0)) { piRenderConfig({ tipo: 'err', texto: 'Indique el tipo y una tarifa válida.' }); return; }
  try {
    await supaFetch(`/clase_tarifas?id=eq.${encodeURIComponent(id)}`, { method: 'PATCH', body: { tipo, monto } });
    await piCargarCatalogos(); piRenderConfig({ tipo: 'ok', texto: `✅ Tarifa de ${tipo} guardada.` });
  } catch (e) { piRenderConfig({ tipo: 'err', texto: /duplicate|unique/i.test(e.message) ? 'Ya existe un tipo de clase con ese nombre.' : 'No se pudo guardar: ' + e.message }); }
}

async function piQuitarTarifa(id) {
  const t = piTarifas.find(x => x.id === id);
  if (!confirm(`¿Quitar la tarifa de ${t ? t.tipo : 'este tipo'}? Las facturas ya cargadas no cambian.`)) return;
  try {
    await supaFetch(`/clase_tarifas?id=eq.${encodeURIComponent(id)}`, { method: 'PATCH', body: { activo: false } });
    await piCargarCatalogos(); piRenderConfig({ tipo: 'ok', texto: 'Tarifa quitada.' });
  } catch (e) { piRenderConfig({ tipo: 'err', texto: 'No se pudo quitar: ' + e.message }); }
}

async function piAgregarTarifa() {
  const tipo = document.getElementById('piTTipoN').value.trim();
  const monto = Number(document.getElementById('piTMontoN').value);
  if (!tipo || !(monto > 0)) { piRenderConfig({ tipo: 'err', texto: 'Indique el tipo y una tarifa válida.' }); return; }
  try {
    const previa = piTarifasTodas.find(t => piNorm(t.tipo) === piNorm(tipo));   // se había quitado: se reactiva
    if (previa) await supaFetch(`/clase_tarifas?id=eq.${encodeURIComponent(previa.id)}`, { method: 'PATCH', body: { tipo, monto, activo: true } });
    else await supaFetch('/clase_tarifas', { method: 'POST', body: { tipo, monto } });
    await piCargarCatalogos(); piRenderConfig({ tipo: 'ok', texto: `✅ Tarifa de ${tipo} agregada.` });
  } catch (e) { piRenderConfig({ tipo: 'err', texto: 'No se pudo agregar: ' + e.message }); }
}

async function piGuardarCedula(id, i) {
  const cedula = piDig(document.getElementById('piIC' + i).value) || null;
  try {
    await supaFetch(`/instructores?id=eq.${encodeURIComponent(id)}`, { method: 'PATCH', body: { cedula } });
    await cargarInstructores(); piRenderConfig({ tipo: 'ok', texto: '✅ Cédula guardada.' });
  } catch (e) { piRenderConfig({ tipo: 'err', texto: /duplicate|unique/i.test(e.message) ? 'Otro instructor ya tiene esa cédula.' : 'No se pudo guardar: ' + e.message }); }
}
