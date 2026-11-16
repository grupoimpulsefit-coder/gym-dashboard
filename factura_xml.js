/* ══════════════════════════════════════════════════════════════════════════
   factura_xml.js — Lectura del XML de la factura electrónica de Hacienda
   (v4.3 / v4.4) y regla del día de pago a instructores.
   Lo usan gastos.html (pagos_instructores.js) y la página pública factura.html.
   La base vuelve a validar todo (pagos_instructores.sql): esto es para mostrar.
   ══════════════════════════════════════════════════════════════════════════ */
const piDig = s => String(s ?? '').replace(/\D/g, '');
const piNorm = s => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/\s+/g, ' ').trim();
const piYMD = d => d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
function piSumarDias(d, n) { const x = new Date(d.getFullYear(), d.getMonth(), d.getDate()); x.setDate(x.getDate() + n); return x; }
const piFechaLarga = d => d.toLocaleDateString('es-CR', { weekday: 'long', day: 'numeric', month: 'long' });

// Fecha y hora de Costa Rica de un instante (por defecto, ahora)
function piAhoraCR(instante) {
  const p = {};
  new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Costa_Rica', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false })
    .formatToParts(instante ? new Date(instante) : new Date()).forEach(x => { p[x.type] = x.value; });
  return new Date(+p.year, +p.month - 1, +p.day, (+p.hour) % 24, +p.minute);
}
// Misma regla que dia_pago_instructor() en la base: corte miércoles y viernes 10:00 a. m.
function piDiaPagoPara(instante) {
  const ahora = piAhoraCR(instante);
  for (let i = 0; i <= 7; i++) {
    const d = piSumarDias(ahora, i);
    if ((d.getDay() === 3 || d.getDay() === 5) && ahora < new Date(d.getFullYear(), d.getMonth(), d.getDate(), 10, 0)) return d;
  }
  return null;
}
const piDiaPagoEstimado = () => piDiaPagoPara();

function piHijo(el, nombre) { return el ? (el.getElementsByTagNameNS('*', nombre)[0] || null) : null; }
function piTexto(el, nombre) { const h = piHijo(el, nombre); return h ? h.textContent.trim() : ''; }

function piParseXML(texto) {
  const doc = new DOMParser().parseFromString(texto, 'application/xml');
  if (doc.getElementsByTagName('parsererror').length) throw new Error('El archivo no es un XML válido.');
  const raiz = doc.documentElement, tipo = raiz.localName;
  if (tipo === 'MensajeHacienda') throw new Error('Este XML es la respuesta de Hacienda (la aceptación), no la factura. Suba el XML de la factura electrónica.');
  if (tipo === 'MensajeReceptor') throw new Error('Este XML es un mensaje de receptor, no la factura. Suba el XML de la factura electrónica.');
  const NOMBRES = { TiqueteElectronico: 'tiquete electrónico', NotaCreditoElectronica: 'nota de crédito', NotaDebitoElectronica: 'nota de débito', FacturaElectronicaCompra: 'factura electrónica de compra', FacturaElectronicaExportacion: 'factura de exportación' };
  if (tipo !== 'FacturaElectronica') {
    throw new Error(NOMBRES[tipo]
      ? `Este documento es un(a) ${NOMBRES[tipo]}. Se necesita una factura electrónica a nombre de la sede.`
      : `No se reconoce el documento (${tipo}). Suba el XML de una factura electrónica.`);
  }
  const emisor = piHijo(raiz, 'Emisor'), receptor = piHijo(raiz, 'Receptor'), resumen = piHijo(raiz, 'ResumenFactura');
  const lineas = [...raiz.getElementsByTagNameNS('*', 'LineaDetalle')].map(l => ({
    cantidad: Number(piTexto(l, 'Cantidad')) || 0,
    detalle: piTexto(l, 'Detalle'),
    total: Number(piTexto(l, 'MontoTotalLinea')) || 0,
  }));
  const x = {
    clave: piDig(piTexto(raiz, 'Clave')),
    consecutivo: piDig(piTexto(raiz, 'NumeroConsecutivo')),
    fecha: piTexto(raiz, 'FechaEmision'),
    emisorNombre: piTexto(emisor, 'Nombre'),
    emisorCedula: piDig(piTexto(piHijo(emisor, 'Identificacion'), 'Numero')),
    receptorNombre: piTexto(receptor, 'Nombre'),
    receptorCedula: piDig(piTexto(piHijo(receptor, 'Identificacion'), 'Numero')),
    moneda: piTexto(resumen, 'CodigoMoneda') || 'CRC',
    total: Number(piTexto(resumen, 'TotalComprobante')) || 0,
    lineas,
    firmado: raiz.getElementsByTagNameNS('http://www.w3.org/2000/09/xmldsig#', 'Signature').length > 0,
  };
  if (!x.clave) throw new Error('El XML no trae la clave de Hacienda: no parece una factura electrónica.');
  if (!(x.total > 0)) throw new Error('No se encontró el total de la factura en el XML.');
  return x;
}
