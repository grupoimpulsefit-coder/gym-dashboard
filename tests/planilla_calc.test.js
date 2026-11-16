// Pruebas del cálculo de planilla (planilla_calc.js). Correr: npm test
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

// Carga los mismos archivos que planilla.html, en el mismo orden
const ctx = vm.createContext({});
for (const f of ['tasas.js', 'planilla_calc.js'])
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', f), 'utf8'), ctx, { filename: f });
const calcularLinea = vm.runInContext('calcularLinea', ctx);
const CCSS_TRABAJADOR = vm.runInContext('CCSS_TRABAJADOR', ctx);

const Q2 = { ini: new Date(2026, 10, 16), fin: new Date(2026, 10, 30) };   // 2.ª quincena de noviembre
const emp = (extra = {}) => ({ id: 'e1', nombre: 'Ana Pérez', salario_mensual: 600000, ...extra });
const cerca = (a, b) => assert.ok(Math.abs(a - b) < 0.01, `${a} ≠ ${b}`);

test('quincena completa: neto = base − CCSS', () => {
  const l = calcularLinea(emp(), Q2, []);
  cerca(CCSS_TRABAJADOR, 0.1083);
  cerca(l.base, 300000);
  cerca(l.ccss, 32490);
  cerca(l.neto, 267510);
});

test('incapacidad CCSS: rebaja los días y suma el subsidio del patrono sin cotizar', () => {
  const nov = [{ empleado_id: 'e1', tipo: 'incapacidad', dias: 4, dias_patrono: 3, pct_patrono: 50 }];
  const l = calcularLinea(emp(), Q2, nov);
  cerca(l.incap, 80000);
  cerca(l.subsidio, 30000);
  cerca(l.bruto, 220000);
  cerca(l.neto, 220000 - 220000 * 0.1083 + 30000);
});

test('feriado, bono y deducción', () => {
  const nov = [
    { empleado_id: 'e1', tipo: 'feriado', dias: 1, factor: 1 },
    { empleado_id: 'e1', tipo: 'bono', monto: 10000 },
    { empleado_id: 'e1', tipo: 'deduccion', monto: 5000 },
    { empleado_id: 'otro', tipo: 'bono', monto: 99999 },   // de otra persona: no cuenta
  ];
  const l = calcularLinea(emp(), Q2, nov);
  cerca(l.bruto, 330000);
  cerca(l.neto, 330000 - 330000 * 0.1083 - 5000);
});

test('las rebajas nunca dejan el salario en negativo', () => {
  const l = calcularLinea(emp(), Q2, [{ empleado_id: 'e1', tipo: 'sin_goce', dias: 20 }]);
  cerca(l.sinGoce, 300000);
  cerca(l.bruto, 0);
  cerca(l.neto, 0);
});

test('ingreso a mitad de quincena paga solo los días trabajados', () => {
  const l = calcularLinea(emp({ fecha_ingreso: '2026-11-20' }), Q2, []);
  cerca(l.base, 11 * 20000);
  assert.match(l.notaBase, /11 días/);
});

test('ingreso después de la quincena: no sale en la planilla', () => {
  assert.strictEqual(calcularLinea(emp({ fecha_ingreso: '2026-12-01' }), Q2, []), null);
});

test('no asegurado: sin CCSS', () => {
  const l = calcularLinea(emp({ asegurado_ccss: false }), Q2, []);
  cerca(l.ccss, 0);
  cerca(l.neto, 300000);
});
