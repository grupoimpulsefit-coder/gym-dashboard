/* Cálculo de la planilla quincenal — lo usa planilla.html y lo prueba
   tests/planilla_calc.test.js. Las tasas CCSS vienen de tasas.js. */
const DIAS_POR_MES = 30;
const DIAS_QUINCENA = 15;
const aseguradoCCSS = e => e.asegurado_ccss !== false;
const salarioDiario = e => (Number(e.salario_mensual) || 0) / DIAS_POR_MES;
// Base de la quincena: el quincenal pactado en RRHH, o la mitad del mensual
const baseQuincena = e => Number(e.salario_quincenal) || (Number(e.salario_mensual) || 0) / 2;

/* ── Cálculo de una línea de planilla ─────────────────────────────────────
   Bruto salarial = base + feriados + bonos − incapacidad − sin goce  (cotiza CCSS)
   Neto = bruto − CCSS trabajador + subsidio de incapacidad − otras deducciones
   El subsidio de incapacidad no es salario, por eso no cotiza. */
function efectoNovedad(n, e){
  const diario = salarioDiario(e), dias = Number(n.dias) || 0;
  switch (n.tipo){
    case 'feriado':     return { feriado: dias * diario * (n.factor ?? 1) };
    case 'sin_goce':    return { sinGoce: dias * diario };
    case 'incapacidad': return { incap: dias * diario,
                                 subsidio: (Number(n.dias_patrono) || 0) * diario * (Number(n.pct_patrono) || 0) / 100 };
    case 'bono':        return { bono: Number(n.monto) || 0 };
    case 'deduccion':   return { deduccion: Number(n.monto) || 0 };
  }
  return {};
}

// q: { ini: Date, fin: Date } de la quincena; novedades: todas las del periodo
function calcularLinea(e, q, novedades){
  const diario = salarioDiario(e);
  let base = baseQuincena(e), notaBase = '';
  // Ingreso a mitad de quincena: se paga solo lo trabajado
  const ing = e.fecha_ingreso ? (([y, m, d]) => new Date(y, m - 1, d))(String(e.fecha_ingreso).split('-').map(Number)) : null;
  if (ing && ing > q.fin) return null;
  if (ing && ing > q.ini){
    // Quincena comercial de 15 días (mes de 30), como el resto de la planilla
    const d = Math.max(1, DIAS_QUINCENA - (ing.getDate() - q.ini.getDate()));
    base = d * diario; notaBase = `ingresó ${ing.toLocaleDateString('es-CR')} · ${d} días`;
  }
  const t = { feriado:0, sinGoce:0, incap:0, subsidio:0, bono:0, deduccion:0 };
  novedades.filter(n => n.empleado_id === e.id).forEach(n => {
    const ef = efectoNovedad(n, e); for (const k in ef) t[k] += ef[k];
  });
  // No se puede rebajar más salario del que hay en la quincena
  const rebajas = Math.min(base + t.feriado + t.bono, t.incap + t.sinGoce);
  const escala = (t.incap + t.sinGoce) ? rebajas / (t.incap + t.sinGoce) : 1;
  t.incap *= escala; t.sinGoce *= escala;
  const bruto = base + t.feriado + t.bono - t.incap - t.sinGoce;
  const ccss = aseguradoCCSS(e) ? bruto * CCSS_TRABAJADOR : 0;
  const patrono = aseguradoCCSS(e) ? bruto * CCSS_PATRONO : 0;
  const neto = bruto - ccss + t.subsidio - t.deduccion;
  return { empleado_id: e.id, nombre: e.nombre, cedula: e.cedula || '', cuenta_bac: e.cuenta_bac || '',
    salario_mensual: Number(e.salario_mensual) || 0, diario, asegurado: aseguradoCCSS(e),
    base, notaBase, ...t, bruto, ccss, patrono, neto };
}
