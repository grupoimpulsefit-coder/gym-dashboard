const test = require('node:test');
const assert = require('node:assert');
const R = require('../reposiciones_nat.js');

test('días a reponer: 24/12 al 03/01 sin 25/12 ni 01/01', () => {
  const d = R.diasAReponer();
  assert.deepStrictEqual(d.map(x => x.fecha), [
    '2026-12-24', '2026-12-26', '2026-12-27', '2026-12-28', '2026-12-29',
    '2026-12-30', '2026-12-31', '2027-01-02', '2027-01-03']);
  assert.strictEqual(d[0].dia, 'Jueves');
  assert.strictEqual(d.find(x => x.fecha === '2026-12-28').dia, 'Lunes');
});

const usuarios = [
  { Nombre: 'Ana Pérez Mora', PIN: '1', Activo: 'Sí', Expira: '15/01/2027', ÚltimoProducto: 'Natación 2x' },
  { Nombre: 'Luis Soto', PIN: '2', Activo: 'Sí', Expira: '29/12/2026', ÚltimoProducto: 'Natación 1x' },
  { Nombre: 'Marta Ruiz', PIN: '3', Activo: 'No', Expira: '10/11/2026', ÚltimoProducto: 'Natación 1x' }
];

test('cuenta por cliente según día de la semana y vencimiento del plan', () => {
  const sesiones = [
    { act: 'Natación adultos', dia: 'Lunes', hora: '6:00 p.m.', personas: ['ANA PEREZ MORA', 'Luis Soto', 'Marta Ruiz', 'Desconocido X'] },
    { act: 'Natación adultos', dia: 'Jueves', hora: '6:00 p.m.', personas: ['Ana Pérez', 'Luis Soto'] },
    { act: 'Natación adultos', dia: 'Viernes', hora: '6:00 p.m.', personas: ['Ana Pérez Mora'] }
  ];
  const { filas, excluidos } = R.calcular(sesiones, usuarios);
  const por = n => filas.filter(f => f.cliente_norm.startsWith(n)).map(f => f.fecha_clase);
  // Ana: lunes 28/12; jueves 24/12 y 31/12; viernes → 25/12 y 01/01 no se reponen
  assert.deepStrictEqual(por('ana').sort(), ['2026-12-24', '2026-12-28', '2026-12-31']);
  // Luis: vence 29/12 → cuenta 24/12 y 28/12, no 31/12
  assert.deepStrictEqual(por('luis').sort(), ['2026-12-24', '2026-12-28']);
  assert.ok(excluidos.some(e => e.cliente === 'Luis Soto' && e.fecha_clase === '2026-12-31' && /vence/.test(e.motivo)));
  assert.ok(excluidos.some(e => e.cliente === 'Marta Ruiz' && e.motivo === 'Inactivo'));
  assert.ok(excluidos.some(e => e.cliente === 'Desconocido X' && /informe/.test(e.motivo)));
  assert.strictEqual(filas.find(f => f.cliente_norm.startsWith('ana')).plan, 'Natación 2x');
});

test('validar fecha de reposición', () => {
  assert.strictEqual(R.validarFechaReposicion('2026-12-10'), null);
  assert.strictEqual(R.validarFechaReposicion('2027-01-31'), null);
  assert.match(R.validarFechaReposicion('2026-11-30'), /01\/12/);
  assert.match(R.validarFechaReposicion('2027-02-01'), /31\/01/);
  assert.match(R.validarFechaReposicion('2026-12-28'), /cerrada/);
  assert.match(R.validarFechaReposicion(''), /fecha/);
});
