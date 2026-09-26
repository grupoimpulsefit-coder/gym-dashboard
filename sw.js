// Service worker mínimo para la app móvil (/movil).
// Cachea SOLO la carcasa (página, manifest, iconos). Nunca cachea Supabase ni otras páginas.
const VERSION = 'impulse-movil-2026-09-26a';
const SHELL = ['/movil', '/manifest.json', '/icons/icon-192.png', '/icons/icon-512.png', '/icons/apple-touch-icon.png', '/icons/favicon-64.png'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(VERSION).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (url.origin !== self.location.origin) return;                 // Supabase, CDNs: directo a red
  if (e.request.method !== 'GET') return;
  const isShell = SHELL.includes(url.pathname);
  if (!isShell && e.request.mode !== 'navigate') return;             // otros recursos: red normal
  if (e.request.mode === 'navigate' && !/^\/movil(\.html)?$/.test(url.pathname)) return;   // solo la app móvil; /caja, /gastos, etc. van directo a red
  // Red primero (para tener siempre la versión nueva); si no hay red, cae al caché de la carcasa.
  e.respondWith(
    fetch(e.request).then((res) => { const copy = res.clone(); caches.open(VERSION).then((c) => c.put(e.request, copy)); return res; })
      .catch(() => caches.match(e.request).then((r) => r || caches.match('/movil')))
  );
});
