/* Cargas sociales CCSS (Costa Rica) — UNA sola fuente para rrhh.html y planilla.html.
   Desglose por rubro; el total se calcula sumando. Verificar con la CCSS/contador:
   cambian con el tiempo (el IVM sube por etapas). */
const RUBROS_TRABAJADOR = [
  { n: 'SEM (Salud)',      p: 5.50 },
  { n: 'IVM (Pensiones)',  p: 4.33 },   // subió de 4.17% → total trabajador 10.83%
  { n: 'Banco Popular',    p: 1.00 },
];
const RUBROS_PATRONO = [
  { n: 'SEM (Salud)',                       p: 9.25 },
  { n: 'IVM (Pensiones)',                   p: 5.42 },
  { n: 'Asignaciones Familiares (FODESAF)', p: 5.00 },
  { n: 'INA',                               p: 1.50 },
  { n: 'IMAS',                              p: 0.50 },
  { n: 'Banco Popular Patronal',            p: 0.50 },
  { n: 'Fondo Capitalización Laboral (FCL)',p: 1.50 },
  { n: 'Pensión Complementaria (ROP)',      p: 1.50 },
  { n: 'Otros aportes patronales',          p: 1.50 },
];
const sumaRubros = arr => arr.reduce((a, r) => a + r.p, 0);
const CCSS_TRABAJADOR = sumaRubros(RUBROS_TRABAJADOR) / 100; // 10.83%
const CCSS_PATRONO    = sumaRubros(RUBROS_PATRONO) / 100;    // 26.67% (solo CCSS; sin póliza de Riesgos del INS)
