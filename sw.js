// DEUK BI — Service Worker v4.0 — Hors ligne complet
const CACHE_VERSION = 'deukbi-v4';

const PRECACHE_URLS = [
  '/index.html',
  '/manifest.json',
  '/icon-192.png',
  '/icon-512.png',
];

// ===== INSTALLATION =====
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_VERSION)
      .then(cache => cache.addAll(PRECACHE_URLS).catch(() => {}))
      .then(() => self.skipWaiting())
  );
});

// ===== ACTIVATION =====
self.addEventListener('activate', event => {
  event.waitUntil(
    Promise.all([
      caches.keys().then(keys =>
        Promise.all(
          keys.filter(k => k !== CACHE_VERSION && k !== 'deukbi-tiles-v1')
              .map(k => caches.delete(k))
        )
      ),
      self.clients.claim()
    ])
  );
  self.clients.matchAll({ includeUncontrolled: true }).then(clients => {
    clients.forEach(c => c.postMessage({ type: 'SW_UPDATED', version: CACHE_VERSION }));
  });
});

// ===== FETCH =====
self.addEventListener('fetch', event => {
  const { request } = event;
  const url = new URL(request.url);

  if (request.method !== 'GET') return;

  // Supabase — jamais de cache (données temps réel)
  if (url.hostname.includes('supabase.co')) return;

  // Tuiles carte ESRI + OSM — cache long terme
  if (url.hostname.includes('arcgisonline.com') ||
      url.hostname.includes('tile.openstreetmap.org') ||
      url.hostname.includes('openstreetmap.org')) {
    event.respondWith(cacheTiles(request));
    return;
  }

  // Fonts, Leaflet, CDN — cache long terme
  if (url.hostname.includes('fonts.googleapis.com') ||
      url.hostname.includes('fonts.gstatic.com') ||
      url.hostname.includes('cdnjs.cloudflare.com') ||
      url.hostname.includes('jsdelivr.net') ||
      url.hostname.includes('unpkg.com')) {
    event.respondWith(cacheFirst(request));
    return;
  }

  // App shell — réseau prioritaire, cache si hors ligne
  event.respondWith(networkFirst(request));
});

// Cache prioritaire
async function cacheFirst(request) {
  const cached = await caches.match(request);
  if (cached) return cached;
  try {
    const response = await fetch(request);
    if (response.ok) {
      (await caches.open(CACHE_VERSION)).put(request, response.clone());
    }
    return response;
  } catch {
    return cached || new Response('Hors ligne', { status: 503 });
  }
}

// Cache tuiles avec limite 1500 tuiles (~75MB)
async function cacheTiles(request) {
  const TILE_CACHE = 'deukbi-tiles-v1';
  const cached = await caches.match(request);
  if (cached) return cached;
  try {
    const response = await fetch(request);
    if (response.ok) {
      const cache = await caches.open(TILE_CACHE);
      const keys = await cache.keys();
      if (keys.length > 1500) {
        await Promise.all(keys.slice(0, 100).map(k => cache.delete(k)));
      }
      cache.put(request, response.clone());
    }
    return response;
  } catch {
    // Hors ligne — retourner tuile en cache ou tuile vide transparente
    return cached || new Response('', { status: 503 });
  }
}

// Réseau prioritaire avec fallback cache
async function networkFirst(request) {
  try {
    const response = await fetch(request);
    if (response.ok) {
      (await caches.open(CACHE_VERSION)).put(request, response.clone());
    }
    return response;
  } catch {
    const cached = await caches.match(request)
                || await caches.match('/index.html');
    return cached || new Response('Hors ligne', { status: 503 });
  }
}

// ===== BACKGROUND SYNC =====
self.addEventListener('sync', event => {
  if (event.tag === 'sync-km') {
    event.waitUntil(
      self.clients.matchAll().then(clients =>
        clients.forEach(c => c.postMessage({ type: 'SYNC_NOW' }))
      )
    );
  }
});

// ===== NOTIFICATIONS PUSH =====
self.addEventListener('push', event => {
  if (!event.data) return;
  const data = event.data.json();
  self.registration.showNotification(data.title || 'DEUK BI 🇸🇳', {
    body: data.body || '',
    icon: '/icon-192.png',
    badge: '/icon-192.png',
    vibrate: [100, 50, 100],
    data: { url: data.url || '/' }
  });
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  event.waitUntil(clients.openWindow(event.notification.data.url));
});
