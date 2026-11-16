/* Utilidades compartidas por todas las páginas (cargar antes del script de la página). */

// Escapa texto para meterlo en HTML (innerHTML, atributos entre comillas)
function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
