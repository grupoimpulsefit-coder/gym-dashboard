/* Pantalla de reposiciones de natación (cierre de fin de año), compartida por
   nat.html (pestaña) e index.html (tarjeta de recepción).
   Requiere reposiciones_nat.js (cálculo) y /ui.css (colores del tema).

   RepoNatUI.montar(el, { supaFetch, rol })
   - admin / admin_sedes: ven el cálculo contra el calendario y el informe de
     usuarios, y son los únicos que lo guardan o recalculan.
   - recepcion / coordinador / admin_sucursal: agendan o registran la
     reposición de los clientes que ya están en el cálculo guardado.
   - Las agendadas en enero se reconfirman (cliente activo ese día); si no lo
     está, la reposición se cancela. Admin puede reconfirmarlas todas juntas
     contra los pagos (Ventas por Producto) y el informe de usuarios.
   La base de datos aplica los mismos permisos (nat_reposiciones.sql). */
(function () {
  const R = window.RepoNat;
  const ROLES_CALCULO = ['admin', 'admin_sedes'];
  const ROLES_REGISTRO = ['admin', 'admin_sedes', 'recepcion', 'coordinador', 'admin_sucursal'];
  const CAL_Q = `/gym_snapshots?sede=eq.${encodeURIComponent('Calendario Natación')}&mes=eq.Semanal`;

  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const clave = r => [r.cliente_norm, r.fecha_clase, r.hora, r.actividad].join('|');
  const dm = f => f ? f.slice(8, 10) + '/' + f.slice(5, 7) : '';
  const dmy = f => f ? dm(f) + '/' + f.slice(0, 4) : '—';
  const hoyIso = () => new Date().toLocaleDateString('en-CA');
  const fmtTs = d => d ? new Date(d).toLocaleString('es-CR', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }) : '—';

  const CSS = `
  .rp { color:var(--label); font-size:14px; }
  .rp-info { background:var(--blue-tint); border-radius:12px; padding:12px 14px; margin-bottom:12px; line-height:1.5; }
  .rp-dim { color:var(--sec); font-size:13px; }
  .rp-cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(160px,1fr)); gap:12px; margin:12px 0; }
  .rp-card { background:var(--card); border-radius:12px; padding:12px 14px; box-shadow:var(--shadow); min-width:0; }
  .rp-card .l { font-size:13px; color:var(--sec); }
  .rp-card .v { font-size:26px; font-weight:700; margin-top:2px; font-variant-numeric:tabular-nums; }
  .rp-card .s { font-size:12px; color:var(--sec); margin-top:2px; }
  .rp-card.full { grid-column:1/-1; }
  .rp-bar { display:flex; gap:10px; flex-wrap:wrap; align-items:center; margin:12px 0; }
  .rp-in { appearance:none; -webkit-appearance:none; background:var(--fill); color:var(--label); border:1.5px solid transparent;
    border-radius:10px; min-height:38px; padding:0 12px; font-size:14px; font-family:inherit; outline:none; box-sizing:border-box; }
  .rp-in:focus { border-color:var(--brand); background:var(--card); }
  .rp-btn { display:inline-flex; align-items:center; gap:6px; min-height:36px; padding:0 14px; border-radius:10px; font-size:14px;
    font-weight:600; cursor:pointer; border:0; font-family:inherit; background:var(--fill); color:var(--brand-text); white-space:nowrap; }
  .rp-btn.pri { background:var(--brand); color:#fff; }
  .rp-btn.sm { min-height:28px; padding:0 10px; font-size:13px; }
  .rp-wrap { overflow-x:auto; border-radius:12px; background:var(--card); box-shadow:var(--shadow); }
  .rp table { width:100%; border-collapse:collapse; }
  .rp th { color:var(--sec); padding:10px 12px; text-align:left; font-size:12px; font-weight:600; text-transform:uppercase;
    letter-spacing:.04em; border-bottom:.5px solid var(--sep); white-space:nowrap; }
  .rp td { padding:9px 12px; border-bottom:.5px solid var(--hair); vertical-align:middle; }
  .rp tr:last-child td { border-bottom:0; }
  .rp-chip { display:inline-flex; align-items:center; height:24px; padding:0 9px; border-radius:12px; font-size:12px; font-weight:600;
    margin:2px; white-space:nowrap; background:var(--orange-tint); color:var(--orange); border:0; font-family:inherit; }
  .rp-chip.tom { background:var(--brand-tint); color:var(--brand-text); }
  .rp-chip.age { background:var(--blue-tint); color:var(--blue); }
  .rp-chip.can { background:var(--red-tint); color:var(--red); text-decoration:line-through; }
  .rp-chip.rec { background:var(--purple-tint); color:var(--purple); }
  button.rp-chip { cursor:pointer; }
  .rp-modal { position:fixed; inset:0; z-index:3000; background:rgba(0,0,0,.45); display:flex; align-items:flex-start;
    justify-content:center; padding:6vh 16px; overflow-y:auto; }
  .rp-modal .box { background:var(--bg); border-radius:16px; width:100%; max-width:460px; padding:18px 20px;
    display:flex; flex-direction:column; gap:12px; box-shadow:0 24px 64px rgba(0,0,0,.35); }
  .rp-modal h3 { font-size:17px; margin:0; }
  .rp-modal label { display:flex; flex-direction:column; gap:4px; font-size:13px; color:var(--sec); }
  .rp-err { color:var(--red); font-size:13px; }
  .rp summary { cursor:pointer; font-weight:600; margin:16px 0 10px; }`;

  function montar(el, { supaFetch, rol }) {
    if (!document.getElementById('rpCss')) {
      const st = document.createElement('style'); st.id = 'rpCss'; st.textContent = CSS; document.head.appendChild(st);
    }
    const puedeCalcular = ROLES_CALCULO.includes(rol);
    const puedeRegistrar = ROLES_REGISTRO.includes(rol);
    const S = { guardadas: [], calc: null, usuarios: new Map(), buscar: null, cargando: false };

    el.classList.add('rp');
    el.innerHTML = `
      <div class="rp-info">La piscina cierra del <b>24/12 al 03/01</b>. Se reponen las clases de esos días
        <b>menos las del 25/12 y el 01/01</b>, a los clientes activos con el plan vigente el día de la clase.
        Se pueden <b>adelantar desde el 01/12</b> o tomar <b>como máximo el 31/01</b>.</div>
      <div class="rp-info" style="background:var(--orange-tint)"><b>⚠️ Importante para recepción:</b> una vez agendada,
        la reposición <b>no se cambia de fecha</b>. Si el cliente avisa que no puede llegar (por ejemplo, la tenía el 05/01
        y pide pasarla al 10/01), <b>la pierde</b>: no se reprograma. Las agendadas en enero se reconfirman; si el
        cliente ya no está activo, se cancelan.</div>
      <div class="rp-dim" data-r="status"></div>
      <div data-r="calc"></div>
      <div class="rp-cards" data-r="cards"></div>
      <div class="rp-bar">
        <input class="rp-in" data-r="q" placeholder="Buscar por nombre o PIN…" style="width:240px;max-width:100%">
        <select class="rp-in" data-r="f">
          <option value="">Todos</option><option value="pend">Con pendientes</option><option value="rec">Enero por reconfirmar</option>
          <option value="canc">Con canceladas</option><option value="comp">Completaron todas</option>
        </select>
        <button class="rp-btn" data-a="csv">⬇️ Exportar CSV</button>
        ${puedeCalcular ? `<label class="rp-btn" style="cursor:pointer">📤 Subir Ventas por Producto
          <input type="file" data-r="ventas" accept=".xlsx,.xls" style="display:none"></label>` : ''}
      </div>
      <div class="rp-wrap"><table>
        <thead><tr><th>Cliente</th><th>Plan</th><th>Vence</th><th>Clases a reponer</th><th>Total</th><th>Tomadas</th><th>Pendientes</th><th></th></tr></thead>
        <tbody data-r="body"></tbody></table></div>
      <details data-r="exclDet" style="display:none"><summary>Clases del cierre que no se reponen (<span data-r="exclN">0</span>)</summary>
        <div class="rp-wrap"><table><thead><tr><th>Cliente</th><th>Clase</th><th>Motivo</th><th>Vence</th></tr></thead>
        <tbody data-r="excl"></tbody></table></div></details>`;
    const $ = k => el.querySelector(`[data-r="${k}"]`);
    $('q').addEventListener('input', render);
    $('f').addEventListener('change', render);
    if ($('ventas')) $('ventas').addEventListener('change', e => { if (e.target.files[0]) subirVentas(e.target.files[0]); e.target.value = ''; });
    el.addEventListener('click', e => {
      const b = e.target.closest('[data-a]');
      if (!b || !el.contains(b)) return;
      const id = +b.dataset.id;
      if (b.dataset.a === 'csv') csv();
      else if (b.dataset.a === 'guardar') guardarCalculo();
      else if (b.dataset.a === 'reg') registrar(id);
      else if (b.dataset.a === 'acc') acciones(id);
      else if (b.dataset.a === 'recAll') reconfirmarEnero();
    });

    async function cargar() {
      if (S.cargando) return;
      S.cargando = true;
      $('status').textContent = '⏳ Cargando reposiciones…';
      try {
        S.guardadas = await supaFetch('/nat_reposiciones?select=*&order=cliente.asc,fecha_clase.asc&limit=20000') || [];
        S.calc = null; S.usuarios = new Map(); S.buscar = null;
        let estado = `${S.guardadas.length} reposiciones guardadas`;
        if (puedeCalcular) {
          const [cal, snaps, pagosSubidos] = await Promise.all([
            supaFetch(CAL_Q + '&limit=1&select=users_data,updated_at'),
            // users_data del más reciente + ventas guardadas de los últimos meses
            supaFetch('/gym_snapshots?sede=eq.Nataci%C3%B3n&order=updated_at.desc&limit=3&select=mes,users_data,renov_data,updated_at'),
            supaFetch('/nat_repo_pagos?select=cliente,fecha,producto&limit=50000').catch(() => [])
          ]);
          const sesiones = cal?.[0]?.users_data?.sesiones || [];
          const usuarios = Array.isArray(snaps?.[0]?.users_data) ? snaps[0].users_data : [];
          // Pagos: los subidos aquí (Ventas por Producto) + las ventas ya guardadas en Natación
          const pagos = [...(pagosSubidos || [])];
          (snaps || []).forEach(sn => (sn.renov_data || []).forEach(r => {
            if (!r.EsClaseSuelta && !r.EsSinClasificar) pagos.push({ cliente: r.Cliente, fecha: r.FechaStr, producto: r.Producto });
          }));
          const efectivos = R.aplicarVentas(usuarios, pagos);
          const conVentas = efectivos.filter(u => u.FuenteVence === 'ventas');
          const ultimoPago = conVentas.reduce((m, u) => u.UltimoPago > m ? u.UltimoPago : m, '');
          if (efectivos.length) S.buscar = R.crearBuscador(efectivos);
          if (sesiones.length && efectivos.length) {
            S.calc = R.calcular(sesiones, efectivos);
            [...S.calc.filas, ...S.calc.excluidos].forEach(f => {
              if (f.plan || f.expira) S.usuarios.set(f.cliente_norm, { plan: f.plan, expira: f.expira });
            });
          }
          estado += ` · Calendario: ${sesiones.length ? 'actualizado ' + fmtTs(cal[0].updated_at) : 'no hay'}` +
            ` · Informe de usuarios: ${usuarios.length ? snaps[0].mes + ', actualizado ' + fmtTs(snaps[0].updated_at) : 'no hay'}` +
            ` · Ventas: ${conVentas.length} clientes con el vencimiento actualizado por pagos${ultimoPago ? ' (último pago ' + dmy(ultimoPago) + ')' : ''}`;
        }
        $('status').textContent = estado;
        render();
      } catch (e) {
        $('status').textContent = '⚠️ No se pudieron cargar las reposiciones: ' + e.message;
      } finally { S.cargando = false; }
    }

    function diff() {
      if (!S.calc) return { nuevas: [], sobran: [] };
      const calc = new Set(S.calc.filas.map(clave)), guard = new Set(S.guardadas.map(clave));
      return {
        nuevas: S.calc.filas.filter(f => !guard.has(clave(f))),
        sobran: S.guardadas.filter(g => g.estado === 'pendiente' && !calc.has(clave(g)))
      };
    }

    function render() {
      const hay = S.guardadas.length > 0;
      // Sin cálculo guardado, el admin ve la vista previa; recepción no ve nada todavía
      const filas = hay ? S.guardadas : (S.calc?.filas || []).map(f => ({ ...f, estado: 'pendiente' }));
      const hoy = hoyIso();

      const { nuevas, sobran } = diff();
      let calcHtml = '';
      if (puedeCalcular) {
        if (!S.calc) calcHtml = `<div class="rp-info">Para calcular hace falta el calendario de reservaciones (pestaña 📅 Calendario de Natación) y los pagos: suba el reporte <b>Ventas por Producto</b> con el botón 📤 (o el informe de usuarios).</div>`;
        else if (!hay) calcHtml = `<div class="rp-info">Vista previa del cálculo — <b>todavía no está guardado</b>; recepción no lo ve hasta guardarlo.
          <button class="rp-btn pri" data-a="guardar" style="margin-left:8px">💾 Guardar cálculo</button></div>`;
        else if (nuevas.length || sobran.length) calcHtml = `<div class="rp-info">Con el calendario y los pagos actuales el cálculo cambió:
          <b>${nuevas.length}</b> reposiciones nuevas y <b>${sobran.length}</b> pendientes que ya no aplican. Las tomadas o agendadas no se tocan.
          <button class="rp-btn pri" data-a="guardar" style="margin-left:8px">🔄 Recalcular</button></div>`;
      } else if (!hay) {
        calcHtml = `<div class="rp-info">Un administrador todavía no ha guardado el cálculo de reposiciones.</div>`;
      }
      const porReconf = S.guardadas.filter(f => R.requiereReconfirmar(f) && !f.confirmada_en);
      if (porReconf.length) calcHtml += `<div class="rp-info" style="background:var(--purple-tint)">
        <b>${porReconf.length}</b> reposiciones agendadas en enero sin reconfirmar. Toque cada una para confirmar que el cliente
        sigue activo; si no lo está, se cancela.
        ${puedeCalcular && S.buscar ? '<button class="rp-btn pri" data-a="recAll" style="margin-left:8px">✔ Reconfirmar todas con los pagos</button>' : ''}</div>`;
      $('calc').innerHTML = calcHtml;

      const tomadas = filas.filter(f => f.estado === 'tomada');
      const canceladas = filas.filter(f => f.estado === 'cancelada');
      const pendientes = filas.filter(f => f.estado === 'pendiente');
      const clientes = new Set(filas.map(f => f.cliente_norm));
      const diasRest = Math.max(0, Math.round((new Date(2027, 0, 31) - new Date(hoy + 'T00:00')) / 86400000) + 1);
      const porDia = R.diasAReponer().map(d =>
        `${d.dia.slice(0, 3)} ${dm(d.fecha)}: <b>${filas.filter(f => f.fecha_clase === d.fecha).length}</b>`).join(' · ');
      $('cards').innerHTML = `
        <div class="rp-card"><div class="l">Clientes con reposición</div><div class="v">${clientes.size}</div></div>
        <div class="rp-card"><div class="l">Reposiciones totales</div><div class="v" style="color:var(--purple)">${filas.length}</div></div>
        <div class="rp-card"><div class="l">Tomadas / agendadas</div><div class="v" style="color:var(--green)">${tomadas.length}</div>
          <div class="s">${tomadas.filter(t => t.fecha_reposicion > hoy).length} agendadas a futuro</div></div>
        <div class="rp-card"><div class="l">Pendientes</div><div class="v" style="color:var(--orange)">${pendientes.length}</div>
          <div class="s">${diasRest} días para tomarlas (hasta 31/01)</div></div>
        <div class="rp-card"><div class="l">Enero por reconfirmar</div><div class="v" style="color:var(--purple)">${porReconf.length}</div></div>
        <div class="rp-card"><div class="l">Canceladas (inactivos)</div><div class="v" style="color:var(--red)">${canceladas.length}</div></div>
        <div class="rp-card full"><div class="l">Clases a reponer por día de cierre</div><div class="s" style="font-size:13px;line-height:1.7;margin-top:6px">${porDia}</div></div>`;

      const grupos = new Map();
      filas.forEach(f => {
        if (!grupos.has(f.cliente_norm)) grupos.set(f.cliente_norm, { cliente: f.cliente, norm: f.cliente_norm, pin: String(f.pin || '').trim(), filas: [] });
        grupos.get(f.cliente_norm).filas.push(f);
      });
      const q = R.fold($('q').value), filtro = $('f').value;
      const lista = [...grupos.values()].filter(g => {
        const pend = g.filas.some(f => f.estado === 'pendiente');
        if (q && !g.norm.includes(q) && !(g.pin && g.pin.toLowerCase().includes(q))) return false;
        if (filtro === 'pend') return pend;
        if (filtro === 'comp') return !pend;
        if (filtro === 'rec') return g.filas.some(f => R.requiereReconfirmar(f) && !f.confirmada_en);
        if (filtro === 'canc') return g.filas.some(f => f.estado === 'cancelada');
        return true;
      }).sort((a, b) => a.cliente.localeCompare(b.cliente, 'es'));

      const puede = hay && puedeRegistrar;
      $('body').innerHTML = lista.map(g => {
        const info = S.usuarios.get(g.norm) || {};
        const plan = info.plan || g.filas[0].plan || '—';
        const expira = info.expira || g.filas[0].expira;
        const tom = g.filas.filter(f => f.estado === 'tomada').length;
        const pen = g.filas.filter(f => f.estado === 'pendiente').length;
        const chips = g.filas.map(f => {
          const base = `${f.dia.slice(0, 3)} ${dm(f.fecha_clase)} ${esc(f.hora)}`;
          const title = esc(f.actividad + (f.nota ? ' — ' + f.nota : '') + (f.registrado_por ? ' — agendó ' + f.registrado_por : ''));
          const tag = puede ? 'button' : 'span';
          const acc = puede ? `data-a="acc" data-id="${f.id}"` : '';
          const cuando = `${dm(f.fecha_reposicion)}${f.hora_reposicion ? ' ' + esc(f.hora_reposicion) : ''}`;
          if (f.estado === 'cancelada')
            return `<${tag} class="rp-chip can" title="${title} — cancelada: ${esc(f.motivo_cancelacion || 'cliente inactivo')}" ${acc}>${base} → ✖ ${cuando}</${tag}>`;
          if (f.estado === 'tomada') {
            const fut = f.fecha_reposicion > hoy;
            const rec = R.requiereReconfirmar(f) && !f.confirmada_en;
            const conf = R.requiereReconfirmar(f) && f.confirmada_en;
            return `<${tag} class="rp-chip ${rec ? 'rec' : fut ? 'age' : 'tom'}" title="${title}${conf ? ' — reconfirmada por ' + esc(f.confirmada_por || '') : ''}" ${acc}>
              ${base} → ${fut ? '📅' : '✔'} ${cuando}${rec ? ' · ⚠ reconfirmar' : conf ? ' · ✔ activo' : ''}</${tag}>`;
          }
          return `<${tag} class="rp-chip" title="${title}" ${puede ? `data-a="reg" data-id="${f.id}"` : ''}>${base}</${tag}>`;
        }).join('');
        const primera = g.filas.find(f => f.estado === 'pendiente');
        // Quién agendó cada reposición, visible en la fila
        const quien = g.filas.filter(f => f.estado !== 'pendiente' && f.registrado_por).map(f =>
          `${f.dia.slice(0, 3)} ${dm(f.fecha_clase)}: agendó <b>${esc(f.registrado_por)}</b>${f.registrado_en ? ' el ' + fmtTs(f.registrado_en) : ''}`).join('<br>');
        return `<tr><td><b>${esc(g.cliente)}</b>${g.pin ? `<div class="rp-dim" style="font-size:12px">PIN ${esc(g.pin)}</div>` : ''}</td><td>${esc(plan)}</td><td>${dmy(expira)}</td>
          <td style="min-width:260px">${chips}${quien ? `<div class="rp-dim" style="font-size:12px;margin-top:4px">${quien}</div>` : ''}</td><td>${g.filas.length}</td><td>${tom}</td><td><b>${pen}</b></td>
          <td>${puede && primera ? `<button class="rp-btn sm" data-a="reg" data-id="${primera.id}">Agendar</button>` : ''}</td></tr>`;
      }).join('') || `<tr><td colspan="8" class="rp-dim" style="text-align:center;padding:20px">Sin reposiciones para mostrar.</td></tr>`;

      const excl = S.calc?.excluidos || [];
      $('exclDet').style.display = puedeCalcular && S.calc ? '' : 'none';
      $('exclN').textContent = excl.length;
      $('excl').innerHTML = excl.map(e => `<tr><td>${esc(e.cliente)}</td>
        <td>${e.dia.slice(0, 3)} ${dm(e.fecha_clase)} ${esc(e.hora)} · ${esc(e.actividad)}</td>
        <td>${esc(e.motivo)}</td><td>${dmy(e.expira)}</td></tr>`).join('');
    }

    async function guardarCalculo() {
      if (!puedeCalcular || !S.calc) return;
      const { nuevas, sobran } = diff();
      if (S.guardadas.length && !confirm(`Se agregan ${nuevas.length} reposiciones y se quitan ${sobran.length} pendientes que ya no aplican. ¿Continuar?`)) return;
      $('status').textContent = '⏳ Guardando cálculo…';
      try {
        const campos = f => ({ cliente: f.cliente, cliente_norm: f.cliente_norm, pin: f.pin || null, plan: f.plan || null,
          expira: f.expira || null, fecha_clase: f.fecha_clase, dia: f.dia, hora: f.hora, actividad: f.actividad });
        for (let i = 0; i < nuevas.length; i += 500)
          await supaFetch('/nat_reposiciones?on_conflict=cliente_norm,fecha_clase,hora,actividad',
            { method: 'POST', prefer: 'resolution=ignore-duplicates,return=minimal', body: nuevas.slice(i, i + 500).map(campos) });
        for (let i = 0; i < sobran.length; i += 150)
          await supaFetch(`/nat_reposiciones?id=in.(${sobran.slice(i, i + 150).map(r => r.id).join(',')})&estado=eq.pendiente`, { method: 'DELETE' });
        await cargar();
      } catch (e) { $('status').textContent = '⚠️ No se pudo guardar: ' + e.message; }
    }

    function registrar(id) {
      const f = S.guardadas.find(r => r.id === id);
      if (!f || !puedeRegistrar) return;
      const pend = S.guardadas.filter(r => r.cliente_norm === f.cliente_norm && r.estado !== 'tomada');
      const C = R.CONFIG;
      const m = document.createElement('div');
      m.className = 'rp-modal rp';
      m.innerHTML = `<div class="box">
        <h3>Agendar reposición — ${esc(f.cliente)}</h3>
        <label>Clase que repone<select class="rp-in" data-m="clase">
          ${pend.map(r => `<option value="${r.id}" ${r.id === id ? 'selected' : ''}>${r.dia} ${dm(r.fecha_clase)} · ${esc(r.hora)} · ${esc(r.actividad)}</option>`).join('')}
        </select></label>
        <label>Fecha de la reposición<input type="date" class="rp-in" data-m="fecha" min="${C.tomarDesde}" max="${C.tomarHasta}" value="${hoyIso()}"></label>
        <label>Hora / clase<input class="rp-in" data-m="hora" placeholder="Ej: 6:00 p.m. adultos"></label>
        <label>Nota (opcional)<input class="rp-in" data-m="nota"></label>
        <div class="rp-dim" style="font-size:12px">Desde el 01/12 hasta el 31/01, nunca del 24/12 al 03/01. Si la fecha es futura queda agendada.</div>
        <div class="rp-info" style="background:var(--orange-tint);margin:0;font-size:13px">⚠️ Avísele al cliente: <b>una vez agendada no se cambia
          de fecha</b>. Si no puede llegar ese día, pierde la reposición.</div>
        <div class="rp-err" data-m="err"></div>
        <div style="display:flex;gap:8px;justify-content:flex-end">
          <button class="rp-btn" data-m="cancelar">Cancelar</button><button class="rp-btn pri" data-m="ok">Guardar</button></div>
      </div>`;
      document.body.appendChild(m);
      const g = k => m.querySelector(`[data-m="${k}"]`);
      const cerrar = () => m.remove();
      m.addEventListener('click', e => { if (e.target === m) cerrar(); });
      g('cancelar').onclick = cerrar;
      g('ok').onclick = async () => {
        const fecha = g('fecha').value, err = R.validarFechaReposicion(fecha);
        if (err) { g('err').textContent = err; return; }
        g('ok').disabled = true;
        try {
          await supaFetch(`/nat_reposiciones?id=eq.${+g('clase').value}&estado=eq.pendiente`, { method: 'PATCH', body: {
            estado: 'tomada', fecha_reposicion: fecha,
            hora_reposicion: g('hora').value.trim() || null, nota: g('nota').value.trim() || null } });
          cerrar();
          await cargar();
        } catch (e) { g('err').textContent = 'No se pudo guardar: ' + e.message; g('ok').disabled = false; }
      };
    }

    const patch = (id, body) => supaFetch(`/nat_reposiciones?id=eq.${id}`, { method: 'PATCH', body });

    // Acciones sobre una reposición ya agendada o cancelada
    function acciones(id) {
      const f = S.guardadas.find(r => r.id === id);
      if (!f || !puedeRegistrar) return;
      const enero = R.requiereReconfirmar(f) || (f.estado === 'cancelada');
      // Sugerencia automática (solo admin tiene los pagos cargados)
      const sug = S.buscar && enero ? R.estadoClienteEn(S.buscar, f.cliente, f.fecha_reposicion) : null;
      const m = document.createElement('div');
      m.className = 'rp-modal rp';
      m.innerHTML = `<div class="box">
        <h3>${esc(f.cliente)}</h3>
        <div>Clase del cierre: <b>${f.dia} ${dm(f.fecha_clase)} · ${esc(f.hora)}</b> · ${esc(f.actividad)}</div>
        <div>Reposición: <b>${dmy(f.fecha_reposicion)}${f.hora_reposicion ? ' · ' + esc(f.hora_reposicion) : ''}</b>
          ${f.registrado_por ? `<br>Agendada por <b>${esc(f.registrado_por)}</b>${f.registrado_en ? ' el ' + fmtTs(f.registrado_en) : ''}` : ''}
          ${f.nota ? `<br>Nota: ${esc(f.nota)}` : ''}
          ${f.estado === 'cancelada' ? `<br><span style="color:var(--red)">Cancelada: ${esc(f.motivo_cancelacion || 'cliente inactivo')}</span>` : ''}
          ${f.confirmada_en ? `<br><span style="color:var(--green)">Reconfirmada activo — ${esc(f.confirmada_por || '')}, ${fmtTs(f.confirmada_en)}</span>` : ''}</div>
        ${sug ? `<div class="rp-info" style="margin:0">Según los pagos registrados: ${sug.activo ? '<b>activo</b>' : '<b>no activo</b> — ' + esc(sug.motivo)}${sug.expira ? ` (vence ${dmy(sug.expira)})` : ''}</div>` : ''}
        ${R.requiereReconfirmar(f) ? `<div class="rp-dim">Reposición de enero: confirme que el cliente sigue activo con su plan al día para esa fecha. Si no lo está, se cancela.</div>` : ''}
        <div class="rp-err" data-m="err"></div>
        <div style="display:flex;flex-direction:column;gap:8px">
          ${R.requiereReconfirmar(f) && !f.confirmada_en ? `<button class="rp-btn pri" data-m="conf">✔ Cliente activo — confirmar</button>` : ''}
          ${R.requiereReconfirmar(f) ? `<button class="rp-btn" data-m="canc" style="color:var(--red)">✖ No está activo — cancelar reposición</button>` : ''}
          ${puedeCalcular ? `<button class="rp-btn" data-m="des">↩ ${f.estado === 'cancelada' ? 'Reactivar' : 'Deshacer'} (solo admin, por error de digitación)</button>`
            : `<div class="rp-dim" style="font-size:12px">Una reposición agendada no se cambia de fecha: si el cliente no llega, la pierde.</div>`}
          <button class="rp-btn" data-m="cerrar">Cerrar</button>
        </div></div>`;
      document.body.appendChild(m);
      const g = k => m.querySelector(`[data-m="${k}"]`);
      const cerrar = () => m.remove();
      m.addEventListener('click', e => { if (e.target === m) cerrar(); });
      g('cerrar').onclick = cerrar;
      const hacer = async body => {
        try { await patch(id, body); cerrar(); await cargar(); }
        catch (e) { g('err').textContent = 'No se pudo guardar: ' + e.message; }
      };
      if (g('conf')) g('conf').onclick = () => hacer({ confirmada_en: new Date().toISOString() });
      if (g('canc')) g('canc').onclick = () => {
        const motivo = prompt('Motivo de la cancelación:', sug && !sug.activo ? sug.motivo : 'Cliente inactivo');
        if (motivo === null) return;
        hacer({ estado: 'cancelada', motivo_cancelacion: motivo.trim() || 'Cliente inactivo' });
      };
      if (g('des')) g('des').onclick = () => {
        if (!confirm('Solo para corregir un error de digitación: si el cliente no llegó o pidió otra fecha, la pierde y no se deshace.\n\nLa reposición vuelve a quedar pendiente y se borra la fecha agendada. ¿Continuar?')) return;
        hacer({ estado: 'pendiente', fecha_reposicion: null, hora_reposicion: null });
      };
    }

    // Admin: reconfirma todas las de enero contra los pagos (ventas + informe de usuarios)
    async function reconfirmarEnero() {
      if (!puedeCalcular || !S.buscar) return;
      const lista = S.guardadas.filter(f => R.requiereReconfirmar(f) && !f.confirmada_en)
        .map(f => ({ f, e: R.estadoClienteEn(S.buscar, f.cliente, f.fecha_reposicion) }));
      const act = lista.filter(x => x.e.activo), ina = lista.filter(x => !x.e.activo);
      if (!confirm(`Según los pagos registrados: ${act.length} siguen activos (se confirman) y ${ina.length} no lo están (se cancelan).\n\n` +
        ina.slice(0, 15).map(x => `✖ ${x.f.cliente} — ${dm(x.f.fecha_reposicion)}: ${x.e.motivo}`).join('\n') +
        (ina.length > 15 ? `\n… y ${ina.length - 15} más` : '') + '\n\n¿Continuar?')) return;
      $('status').textContent = '⏳ Reconfirmando…';
      try {
        const ahora = new Date().toISOString();
        for (let i = 0; i < act.length; i += 150)
          await supaFetch(`/nat_reposiciones?id=in.(${act.slice(i, i + 150).map(x => x.f.id).join(',')})&estado=eq.tomada`,
            { method: 'PATCH', body: { confirmada_en: ahora } });
        for (const x of ina) await patch(x.f.id, { estado: 'cancelada', motivo_cancelacion: x.e.motivo });
        await cargar();
      } catch (e) { $('status').textContent = '⚠️ No se pudo reconfirmar: ' + e.message; }
    }

    // Admin: sube "Ventas por Producto"; se guardan las mensualidades de natación
    // (nat_repo_pagos) y cada pago extiende el plan del cliente un mes.
    async function subirVentas(file) {
      if (!puedeCalcular) return;
      $('status').textContent = '⏳ Leyendo Ventas por Producto…';
      try {
        if (!window.XLSX) throw new Error('No se cargó el lector de Excel; recargue la página.');
        const wb = XLSX.read(new Uint8Array(await file.arrayBuffer()), { type: 'array', cellDates: false });
        const raw = XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1, defval: '' });
        let h = -1, col = {};
        for (let i = 0; i < Math.min(raw.length, 10); i++) {
          const r = (raw[i] || []).map(c => String(c || '').trim().toLowerCase());
          if (r.includes('fecha') && r.includes('producto')) {
            h = i; col = { fecha: r.indexOf('fecha'), producto: r.indexOf('producto'), cliente: r.indexOf('cliente'),
              total: r.findIndex(c => c.includes('total crc')) };
            if (col.total < 0) col.total = r.findIndex(c => c.includes('total') && !c.includes('usd'));
            break;
          }
        }
        if (h < 0 || col.cliente < 0) throw new Error('No se encontró el encabezado (Fecha / Cliente / Producto). Verifique que sea el reporte "Ventas por Producto".');
        const fechaIso = v => {
          if (typeof v === 'number' && XLSX.SSF) { const d = XLSX.SSF.parse_date_code(v); return d ? `${d.y}-${String(d.m).padStart(2, '0')}-${String(d.d).padStart(2, '0')}` : null; }
          return R.expiraIso(v);
        };
        const vistos = new Set(), filas = [];
        raw.slice(h + 1).forEach(r => {
          const cliente = String(r[col.cliente] || '').trim().replace(/\s+/g, ' ');
          const producto = String(r[col.producto] || '').trim();
          const fecha = fechaIso(r[col.fecha]);
          const total = col.total >= 0 ? Number(r[col.total]) || 0 : null;
          if (!cliente || !fecha || !R.esPagoPlanNatacion(producto) || (total !== null && total <= 0)) return;
          const fila = { cliente, cliente_norm: R.fold(cliente), fecha, producto, total };
          const k = [fila.cliente_norm, fecha, producto].join('|');
          if (!vistos.has(k)) { vistos.add(k); filas.push(fila); }
        });
        if (!filas.length) throw new Error('El archivo no tiene pagos de planes de natación.');
        for (let i = 0; i < filas.length; i += 500)
          await supaFetch('/nat_repo_pagos?on_conflict=cliente_norm,fecha,producto',
            { method: 'POST', prefer: 'resolution=ignore-duplicates,return=minimal', body: filas.slice(i, i + 500) });
        const fs = filas.map(f => f.fecha).sort();
        alert(`✅ ${filas.length} pagos de natación guardados (${dmy(fs[0])} al ${dmy(fs[fs.length - 1])}).\n\nSi el cálculo cambió, revise y pulse "Recalcular".`);
        await cargar();
      } catch (e) { $('status').textContent = '⚠️ No se pudieron subir las ventas: ' + e.message; }
    }

    function csv() {
      const filas = S.guardadas.length ? S.guardadas : (S.calc?.filas || []);
      const q = v => '"' + String(v ?? '').replace(/"/g, '""') + '"';
      const txt = ['Cliente,PIN,Plan,Clase cerrada,Día,Hora,Actividad,Estado,Fecha reposición,Hora reposición,Nota,Agendó,Fecha en que se agendó,Reconfirmada,Motivo cancelación']
        .concat(filas.map(f => [f.cliente, f.pin, f.plan, f.fecha_clase, f.dia, f.hora, f.actividad, f.estado || 'pendiente',
          f.fecha_reposicion, f.hora_reposicion, f.nota, f.registrado_por,
          f.registrado_en ? new Date(f.registrado_en).toLocaleString('es-CR') : '',
          f.confirmada_en ? (f.confirmada_por || 'sí') : '', f.motivo_cancelacion].map(q).join(','))).join('\n');
      const a = document.createElement('a');
      a.href = URL.createObjectURL(new Blob(['﻿' + txt], { type: 'text/csv;charset=utf-8' }));
      a.download = 'reposiciones-natacion-' + hoyIso() + '.csv';
      a.click(); setTimeout(() => URL.revokeObjectURL(a.href), 1000);
    }

    cargar();
    return { recargar: cargar };
  }

  window.RepoNatUI = { montar, ROLES_CALCULO, ROLES_REGISTRO };
})();
