// Service worker: guarda os arquivos do app para abrir rápido e funcionar como app instalado.
// Os compromissos sempre vêm do servidor (não ficam neste cache).
const CACHE = "agenda-a-dois-v13";
const FILES = ["./", "./index.html", "./config.js", "./manifest.webmanifest", "./icon.svg", "./icon-192.png", "./icon-512.png", "./apple-touch-icon.png"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(FILES)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE && k !== "agenda-state").map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin) return; // API do Supabase passa direto
  // rede primeiro, cache se estiver offline
  e.respondWith(
    fetch(e.request, { cache: "no-cache" }).then(r => { const copy = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); return r; })
      .catch(() => caches.match(e.request).then(r => r || caches.match("./index.html")))
  );
});

// Notificações: mostra o aviso e abre o app ao tocar.
self.addEventListener("push", e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { body: e.data ? e.data.text() : "" }; }
  // Soma 1 no número vermelho do ícone do app.
  const bump = async () => {
    const c = await caches.open("agenda-state");
    const r = await c.match("badge");
    const n = (r ? parseInt(await r.text(), 10) || 0 : 0) + 1;
    await c.put("badge", new Response(String(n)));
    if (self.navigator && self.navigator.setAppBadge) await self.navigator.setAppBadge(n);
  };
  e.waitUntil(Promise.all([
    self.registration.showNotification(d.title || "Agenda", {
      body: d.body || "", icon: "icon-192.png", badge: "icon-192.png", data: { url: d.url || "./" }
    }),
    bump().catch(() => {})
  ]));
});
self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || "./";
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(list => {
    for (const c of list) if ("focus" in c) return c.focus();
    return self.clients.openWindow(url);
  }));
});

// Se o celular trocar a inscrição de notificações, refaz sozinho em todas as agendas.
self.addEventListener("pushsubscriptionchange", e => {
  e.waitUntil((async () => {
    const c = await caches.open("agenda-state");
    const r = await c.match("state");
    if (!r) return;
    const st = await r.json();
    const pad = "=".repeat((4 - st.vapid.length % 4) % 4);
    const raw = atob((st.vapid + pad).replace(/-/g, "+").replace(/_/g, "/"));
    const key = Uint8Array.from(raw, ch => ch.charCodeAt(0));
    const sub = (await self.registration.pushManager.getSubscription()) ||
      (await self.registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key }));
    const j = sub.toJSON();
    for (const code of st.codes || []) {
      await fetch(st.url + "/rest/v1/rpc/agenda_subscribe", {
        method: "POST", headers: { "Content-Type": "application/json", apikey: st.key },
        body: JSON.stringify({ p_code: code, p_name: st.name, p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth })
      }).catch(() => {});
    }
  })());
});
