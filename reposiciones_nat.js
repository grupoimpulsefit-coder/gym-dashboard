/* Reposiciones de natación por el cierre de fin de año.
   Cálculo puro (sin DOM ni Supabase) para poder probarlo con `node --test`.
   nat.html lo usa en la pestaña "Reposiciones". */
(function (root) {
  const CONFIG = {
    cierreDesde: '2026-12-24',
    cierreHasta: '2027-01-03',
    noSeReponen: ['2026-12-25', '2027-01-01'],
    tomarDesde: '2026-12-01',   // se pueden adelantar en diciembre…
    tomarHasta: '2027-01-31'    // …o tomar como máximo en enero
  };
  const DIAS = ['Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo'];

  const fold = s => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toLowerCase().replace(/\s+/g, ' ').trim();

  const iso = d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const deIso = s => { const [y, m, d] = s.split('-').map(Number); return new Date(y, m - 1, d); };

  // "dd/mm/yyyy" (o yyyy-mm-dd) → 'yyyy-mm-dd'; null si no se entiende
  function expiraIso(v) {
    if (!v) return null;
    const s = String(v).trim();
    let m = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{2,4})/);
    if (m) { let y = +m[3]; if (y < 100) y += 2000; return iso(new Date(y, +m[2] - 1, +m[1])); }
    m = s.match(/^(\d{4})-(\d{2})-(\d{2})/);
    return m ? `${m[1]}-${m[2]}-${m[3]}` : null;
  }

  // 'yyyy-mm-dd' + 1 mes (31/01 → 28/02)
  function sumarMes(f) {
    const [y, m, d] = f.split('-').map(Number);
    const ult = new Date(y, m + 1, 0).getDate();      // último día del mes siguiente
    return iso(new Date(y, m, Math.min(d, ult)));
  }

  // ¿La venta es una mensualidad de natación? (Ventas por Producto)
  function esPagoPlanNatacion(producto) {
    const p = fold(producto);
    return /nataci|aquafit|aquaterap|estimulaci/.test(p) && !/reposici|matricul|suelta|sesion/.test(p);
  }

  /* Vencimientos a partir de Ventas por Producto, sin depender del informe de usuarios.
     usuarios (opcional): informe de usuarios, da el vencimiento de partida.
     pagos: [{ cliente, fecha:'yyyy-mm-dd' o 'dd/mm/yyyy …', producto }]
     Cada mensualidad de natación extiende el plan un mes desde el vencimiento
     (o desde el día del pago si ya estaba vencido). Un pago hecho más de 10 días
     antes del vencimiento conocido se toma como ya incluido en ese vencimiento.
     → usuarios con Expira actualizado (yyyy-mm-dd) + los que solo aparecen en ventas */
  function aplicarVentas(usuarios, pagos) {
    const lista = (usuarios || []).map(u => ({ ...u, Expira: expiraIso(u.Expira) || u.Expira }));
    const buscar = crearBuscador(lista);
    const nuevos = new Map();
    (pagos || [])
      .map(p => ({ ...p, fecha: expiraIso(p.fecha || p.FechaStr), cliente: p.cliente || p.Cliente, producto: p.producto || p.Producto }))
      .filter(p => p.fecha && p.cliente && esPagoPlanNatacion(p.producto))
      .sort((a, b) => a.fecha.localeCompare(b.fecha))
      .forEach(p => {
        let u = buscar(p.cliente);
        if (!u) {
          const k = fold(p.cliente);
          if (!nuevos.has(k)) nuevos.set(k, { Nombre: p.cliente.trim().replace(/\s+/g, ' '), PIN: '', Activo: 'Sí', Expira: null });
          u = nuevos.get(k);
        }
        const exp = expiraIso(u.Expira);
        const limite = exp ? iso(new Date(deIso(exp).getTime() - 10 * 86400000)) : null;
        if (exp && p.fecha < limite) return;                // ya incluido en el vencimiento del informe
        u.Expira = sumarMes(exp && exp > p.fecha ? exp : p.fecha);
        u.Activo = 'Sí';
        u.ÚltimoProducto = p.producto.replace(/\(Promo:[^)]*\)/i, '').replace(/\s+/g, ' ').trim();
        u.UltimoPago = p.fecha;
        u.FuenteVence = 'ventas';
      });
    return lista.concat([...nuevos.values()]);
  }

  // Días cerrados que sí se reponen: [{ fecha:'2026-12-24', dia:'Jueves' }, …]
  function diasAReponer(cfg = CONFIG) {
    const out = [];
    for (let d = deIso(cfg.cierreDesde); iso(d) <= cfg.cierreHasta; d.setDate(d.getDate() + 1)) {
      const f = iso(d);
      if (!cfg.noSeReponen.includes(f)) out.push({ fecha: f, dia: DIAS[(d.getDay() + 6) % 7] });
    }
    return out;
  }

  // Empata nombres del calendario con el informe de usuarios: primero exacto
  // (sin tildes ni mayúsculas); si no, por palabras (todas las del nombre más
  // corto aparecen en el otro) y solo si hay un único candidato.
  function crearBuscador(usuarios) {
    const porNombre = new Map();
    usuarios.forEach(u => {
      const k = fold(u.Nombre);
      if (!k) return;
      const prev = porNombre.get(k);
      // nombres repetidos: se queda el de vencimiento más lejano
      if (!prev || (expiraIso(u.Expira) || '') > (expiraIso(prev.Expira) || '')) porNombre.set(k, u);
    });
    const lista = [...porNombre.entries()].map(([k, u]) => ({ k, set: new Set(k.split(' ')), u }));
    return nombre => {
      const k = fold(nombre);
      if (porNombre.has(k)) return porNombre.get(k);
      const pal = k.split(' ');
      if (pal.length < 2) return null;
      const cand = lista.filter(x => {
        const [corto, largo] = pal.length <= x.set.size ? [pal, x.set] : [[...x.set], new Set(pal)];
        return corto.length >= 2 && corto.every(p => largo.has(p));
      });
      return cand.length === 1 ? cand[0].u : null;
    };
  }

  /* sesiones: [{ act, dia, hora, personas:[nombre…] }] (calendario semanal)
     usuarios: [{ Nombre, PIN, Activo, Expira, ÚltimoProducto }] (informe de usuarios)
     → { filas: [una por clase a reponer], excluidos: [una por clase que no se repone] } */
  function calcular(sesiones, usuarios, cfg = CONFIG) {
    const dias = diasAReponer(cfg);
    const buscar = crearBuscador(usuarios || []);
    const filas = [], excluidos = [], vistos = new Set();
    (sesiones || []).forEach(s => {
      const fechas = dias.filter(d => d.dia === s.dia);
      if (!fechas.length) return;
      (s.personas || []).forEach(nombre => {
        const u = buscar(nombre);
        const exp = u ? expiraIso(u.Expira) : null;
        fechas.forEach(({ fecha }) => {
          const clave = [fold(nombre), fecha, s.hora, s.act].join('|');
          if (vistos.has(clave)) return;          // misma persona repetida en la sesión
          vistos.add(clave);
          const base = { cliente: nombre.trim(), cliente_norm: fold(nombre), fecha_clase: fecha,
                         dia: s.dia, hora: s.hora, actividad: s.act };
          let motivo = null;
          if (!u) motivo = 'Sin pagos ni registro en el informe de usuarios';
          else if (/^no/i.test(String(u.Activo || '').trim())) motivo = 'Inactivo';
          else if (!exp) motivo = 'Sin fecha de vencimiento';
          else if (exp < fecha) motivo = 'Plan vence antes de la clase';
          const extra = u ? { pin: u.PIN || null, plan: u.ÚltimoProducto || null, expira: exp } : {};
          if (motivo) excluidos.push({ ...base, ...extra, motivo });
          else filas.push({ ...base, ...extra });
        });
      });
    });
    const orden = (a, b) => a.cliente.localeCompare(b.cliente, 'es') || a.fecha_clase.localeCompare(b.fecha_clase);
    return { filas: filas.sort(orden), excluidos: excluidos.sort(orden) };
  }

  // Reconfirmación de una reposición agendada: ¿el cliente sigue activo con el
  // plan vigente el día de la reposición?  → { activo, motivo, expira }
  function estadoClienteEn(buscar, nombre, fecha) {
    const u = buscar(nombre);
    if (!u) return { activo: false, motivo: 'Sin pagos ni registro en el informe de usuarios' };
    const exp = expiraIso(u.Expira);
    if (/^no/i.test(String(u.Activo || '').trim()) && !(exp && exp >= fecha)) return { activo: false, motivo: 'Inactivo', expira: exp };
    if (!exp) return { activo: false, motivo: 'Sin fecha de vencimiento' };
    if (exp < fecha) return { activo: false, motivo: `Plan venció el ${exp.slice(8, 10)}/${exp.slice(5, 7)}`, expira: exp };
    return { activo: true, expira: exp };
  }
  const requiereReconfirmar = r => r.estado === 'tomada' && (r.fecha_reposicion || '') > CONFIG.cierreHasta;

  // ¿Se puede registrar una reposición en esta fecha?  null = sí; si no, el motivo
  function validarFechaReposicion(fecha, cfg = CONFIG) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(fecha || '')) return 'Indique la fecha en que tomó la clase.';
    if (fecha < cfg.tomarDesde || fecha > cfg.tomarHasta)
      return 'La reposición se toma entre el 01/12/2026 y el 31/01/2027.';
    if (fecha >= cfg.cierreDesde && fecha <= cfg.cierreHasta)
      return 'Esa fecha la piscina está cerrada (24/12 al 03/01).';
    return null;
  }

  const api = { CONFIG, DIAS, fold, expiraIso, sumarMes, esPagoPlanNatacion, aplicarVentas, diasAReponer, crearBuscador, calcular, validarFechaReposicion,
                estadoClienteEn, requiereReconfirmar };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.RepoNat = api;
})(typeof window !== 'undefined' ? window : globalThis);
