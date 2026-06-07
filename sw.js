/* Service Worker — Agracta
   - HTML (navegação): network-first (sempre pega a versão nova online; cache só como reserva offline)
   - Estáticos (vendor, ícones): cache-first
   - Nunca intercepta o proxy NDVI / tiles do satélite / Copernicus */
var CACHE = 'agracta-app-v24';
var ASSETS = [
  './', './index.html',
  './vendor/leaflet.js', './vendor/leaflet.css',
  './vendor/leaflet-rotate.js',
  './vendor/Leaflet.ImageOverlay.Rotated.js',
  './vendor/quadras-default.js', './vendor/supabase.js', './vendor/xlsx.full.min.js',
  './manifest.webmanifest', './icon-192.png', './icon-512.png'
];
self.addEventListener('install', function(e){
  e.waitUntil(caches.open(CACHE).then(function(c){ return c.addAll(ASSETS); }).then(function(){ return self.skipWaiting(); }));
});
self.addEventListener('activate', function(e){
  e.waitUntil(caches.keys().then(function(ks){
    return Promise.all(ks.map(function(k){ if(k!==CACHE) return caches.delete(k); }));
  }).then(function(){ return self.clients.claim(); }));
});
self.addEventListener('fetch', function(e){
  if(e.request.method !== 'GET') return;
  var u = new URL(e.request.url);
  /* Online sempre (sem cache): proxy NDVI, tiles do satélite e Copernicus */
  if(u.port === '8799' || u.hostname.indexOf('onrender.com') >= 0 || u.hostname.indexOf('supabase.co') >= 0 ||
     u.hostname.indexOf('arcgisonline') >= 0 || u.hostname.indexOf('google.com') >= 0 || u.hostname.indexOf('dataspace') >= 0) return;
  var isHTML = e.request.mode === 'navigate' || u.pathname.endsWith('/') || u.pathname.endsWith('index.html');
  if(isHTML){
    e.respondWith(
      fetch(e.request).then(function(resp){
        var copy = resp.clone();
        caches.open(CACHE).then(function(c){ c.put('./index.html', copy); });
        return resp;
      }).catch(function(){ return caches.match('./index.html').then(function(r){ return r || caches.match('./'); }); })
    );
    return;
  }
  e.respondWith(caches.match(e.request).then(function(r){ return r || fetch(e.request); }));
});
