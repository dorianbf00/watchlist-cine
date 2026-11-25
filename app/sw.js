// Service worker « Watchlist au ciné » : seulement les notifications Web Push (aucun cache, la page reste toujours fraîche)
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

self.addEventListener('push', (e) => {
  let n = {};
  try { n = e.data ? e.data.json() : {}; } catch { n = { body: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(n.title || 'Watchlist au ciné', {
    body: n.body || '',
    icon: 'icon-192.png',
    badge: 'icon-192.png',
    data: { url: n.url || './' },
  }));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const url = new URL(e.notification.data?.url || './', self.registration.scope).href;
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const w = wins.find((c) => c.url.startsWith(self.registration.scope));
    if (w) { await w.focus(); return w.navigate ? w.navigate(url).catch(() => {}) : null; }
    return self.clients.openWindow(url);
  })());
});
