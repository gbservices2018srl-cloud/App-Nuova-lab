self.addEventListener('push', event => {
  let data = { title: 'Nuovalab', body: 'Hai un nuovo messaggio' };
  try { data = event.data.json(); } catch(e) {}
  event.waitUntil(
    self.registration.showNotification(data.title || 'Nuovalab', {
      body: data.body || '',
      icon: 'https://raw.githubusercontent.com/twitter/twemoji/master/assets/72x72/1f9b7.png',
      badge: 'https://raw.githubusercontent.com/twitter/twemoji/master/assets/72x72/1f9b7.png'
    })
  );
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  event.waitUntil(
    clients.matchAll({ type: 'window' }).then(windowClients => {
      for (const client of windowClients) {
        if ('focus' in client) return client.focus();
      }
      if (clients.openWindow) return clients.openWindow('/');
    })
  );
});
