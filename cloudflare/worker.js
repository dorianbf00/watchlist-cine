// Relais Cloudflare Worker (gratuit) de « Watchlist au ciné »
//
// 1. POST /            « tirer pour actualiser »
//    La page publique appelle ce relais ; lui seul détient le token GitHub (secret GITHUB_TOKEN du Worker)
//    et lance le workflow "Watchlist au cinéma" (workflow_dispatch). Au plus une relance toutes les 10 min.
//    Réponse JSON { state } :
//      started : relance lancée            running : une mise à jour tourne déjà
//      fresh   : dernière mise à jour il y a moins de 10 min (rien à faire, la page est à jour)
//      error   : souci côté GitHub (token expiré, etc.)
//
// 2. Notifications Web Push (remplacent ntfy : la notif porte l'icône de l'appli)
//    GET  /push/key          clé publique VAPID (la paire est créée au 1er appel et rangée dans le KV)
//    POST /push/subscribe    la page enregistre l'abonnement du téléphone (+ notif de bienvenue)
//    POST /push/unsubscribe  { endpoint } : la page désactive les notifs
//    POST /push/send         { title, message, click } — réservé à l'Action GitHub
//                            (en-tête Authorization: Bearer <secret PUSH_SECRET du Worker>)
//    Liaison KV requise : namespace lié sous le nom PUSH.
//
// 3. Autres utilisateurs (chacun voit SA watchlist ; les séances, elles, sont communes)
//    POST /user   { user, refresh? }  la page enregistre un pseudo Letterboxd. Si sa watchlist n'est pas encore
//                 connue (ou refresh et vérifiée il y a plus de 10 min), on lance le workflow "users.yml" pour ce pseudo.
//                 Réponse { state: ready | pending | notfound | owner | error, wl? }
//    GET  /wl?u=  watchlist connue d'un pseudo : { state: ready, user, updated, count, slugs } (ou pending / notfound)
//    GET  /users  liste des pseudos + date de vérification de leur watchlist  } réservés au workflow "users.yml"
//    POST /wl     { user, slugs } ou { user, error: 'notfound' }             } (en-tête Bearer PUSH_SECRET)
//    Les watchlists sont récupérées par GitHub Actions (curl passe l'anti-robot de Letterboxd) et rangées
//    dans le KV PUSH sous wl:<pseudo> ; les pseudos sous user:<pseudo> (métadonnée = date de vérification).

const REPO = 'dorianbf00/watchlist-cine';
const WORKFLOW = 'watchlist-cine.yml';
const USERS_WORKFLOW = 'users.yml';
const OWNER = 'vertpisse00';   // ta watchlist : celle de la page publiée (et des abonnés sans pseudo)
const USER_RE = /^[a-z0-9_]{2,30}$/;
const COOLDOWN_MIN = 10;
const ALLOWED = ['https://dorianbf00.github.io', 'http://localhost:8080'];
const PAGE_URL = 'https://dorianbf00.github.io/watchlist-cine/';
// Services de push des navigateurs (Apple, Google, Mozilla, Microsoft) : on n'envoie nulle part ailleurs
const PUSH_HOSTS = /^(web\.push\.apple\.com|fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|[\w.-]+\.notify\.windows\.com)$/;

export default {
  async fetch(req, env) {
    const origin = req.headers.get('Origin') || '';
    const cors = {
      'Access-Control-Allow-Origin': ALLOWED.includes(origin) ? origin : ALLOWED[0],
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
      'Vary': 'Origin',
    };
    const json = (body, status = 200) =>
      new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
    const reply = (state, extra = {}, status = 200) => json({ state, ...extra }, status);

    if (req.method === 'OPTIONS') return new Response(null, { headers: cors });

    const url = new URL(req.url);
    const path = url.pathname.replace(/\/+$/, '');
    if (path.startsWith('/push')) {
      try { return await push(path, req, env, origin, json); }
      catch (e) { return json({ ok: false, message: String(e?.message || e) }, 500); }
    }
    if (['/user', '/users', '/wl'].includes(path)) {
      try { return await users(path, url, req, env, origin, json); }
      catch (e) { return json({ state: 'error', message: String(e?.message || e) }, 500); }
    }

    if (req.method !== 'POST') return reply('error', { message: 'POST uniquement' }, 405);
    if (!ALLOWED.includes(origin)) return reply('error', { message: 'origine refusée' }, 403);

    const gh = github(env);

    // Dernière exécution du workflow (planifiée, manuelle ou relance) : sert de garde-fou anti-abus
    const runs = await gh(`/actions/workflows/${WORKFLOW}/runs?per_page=1`);
    if (!runs.ok) return reply('error', { message: `GitHub ${runs.status}` }, 502);
    const last = (await runs.json()).workflow_runs?.[0];
    if (last) {
      if (last.status !== 'completed') return reply('running', { since: last.created_at });
      const age = (Date.now() - Date.parse(last.updated_at)) / 60e3;
      if (age < COOLDOWN_MIN) return reply('fresh', { retryInMin: Math.ceil(COOLDOWN_MIN - age) });
    }

    const go = await gh(`/actions/workflows/${WORKFLOW}/dispatches`, {
      method: 'POST',
      body: JSON.stringify({ ref: 'main', inputs: { source: 'app' } }),
    });
    if (!go.ok) return reply('error', { message: `GitHub ${go.status}` }, 502);
    return reply('started');
  },
};

const github = (env) => (path, init = {}) => fetch(`https://api.github.com/repos/${REPO}${path}`, {
  ...init,
  headers: {
    'Authorization': `Bearer ${env.GITHUB_TOKEN}`,
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'watchlist-cine-refresh',
    ...(init.body ? { 'Content-Type': 'application/json' } : {}),
  },
});

const authorized = (req, env) => env.PUSH_SECRET && req.headers.get('Authorization') === `Bearer ${env.PUSH_SECRET}`;
const cleanUser = (u) => { const s = String(u || '').trim().toLowerCase().replace(/^@/, ''); return USER_RE.test(s) ? s : ''; };
const minutesSince = (iso) => (iso ? (Date.now() - Date.parse(iso)) / 60e3 : Infinity);

// --- Autres utilisateurs -----------------------------------------------------------

async function users(path, url, req, env, origin, json) {
  if (!env.PUSH) return json({ state: 'error', message: 'KV "PUSH" non lié au Worker' }, 500);

  if (path === '/wl' && req.method === 'GET') {
    const u = cleanUser(url.searchParams.get('u'));
    if (!u) return json({ state: 'error', message: 'pseudo invalide' }, 400);
    const wl = await env.PUSH.get('wl:' + u, 'json');
    if (wl?.error === 'notfound') return json({ state: 'notfound' });
    if (!wl) return json({ state: 'pending' });
    const { metadata } = await env.PUSH.getWithMetadata('user:' + u);
    return json({ state: 'ready', ...wl, checked: metadata?.checked || wl.updated });
  }

  if (path === '/users' && req.method === 'GET') {
    if (!authorized(req, env)) return json({ ok: false, message: 'non autorisé' }, 401);
    const out = []; let cursor;
    do {
      const page = await env.PUSH.list({ prefix: 'user:', cursor });
      for (const k of page.keys) out.push({ user: k.name.slice(5), checked: k.metadata?.checked || null });
      cursor = page.list_complete ? null : page.cursor;
    } while (cursor);
    return json({ ok: true, users: out });
  }

  if (req.method !== 'POST') return json({ state: 'error', message: 'méthode refusée' }, 405);
  const body = await req.json().catch(() => ({}));
  const u = cleanUser(body.user);
  if (!u) return json({ state: 'error', message: 'pseudo invalide' }, 400);

  if (path === '/wl') {
    if (!authorized(req, env)) return json({ ok: false, message: 'non autorisé' }, 401);
    const now = new Date().toISOString();
    if (body.error === 'notfound') {
      // Pseudo inconnu ou watchlist privée : on l'oublie (la page le redemandera)
      await env.PUSH.put('wl:' + u, JSON.stringify({ error: 'notfound', updated: now }), { expirationTtl: 3600 });
      await env.PUSH.delete('user:' + u);
      return json({ ok: true });
    }
    const slugs = [...new Set((body.slugs || []).map(String).filter((x) => /^[a-z0-9-]{1,200}$/.test(x)))].sort();
    // On n'écrit la watchlist que si elle a changé (quota gratuit : 1 000 écritures KV / jour)
    const old = await env.PUSH.get('wl:' + u, 'json');
    const same = old?.slugs && old.slugs.length === slugs.length && old.slugs.every((x, i) => x === slugs[i]);
    if (!same) await env.PUSH.put('wl:' + u, JSON.stringify({ user: u, updated: now, count: slugs.length, slugs }));
    await env.PUSH.put('user:' + u, '1', { metadata: { checked: now } });
    return json({ ok: true, changed: !same, count: slugs.length });
  }

  // POST /user : seulement depuis la page
  if (!ALLOWED.includes(origin)) return json({ state: 'error', message: 'origine refusée' }, 403);
  if (u === OWNER) return json({ state: 'owner' });
  const wl = await env.PUSH.get('wl:' + u, 'json');
  if (wl?.error === 'notfound') return json({ state: 'notfound' });
  const known = await env.PUSH.getWithMetadata('user:' + u);
  if (!known.value) await env.PUSH.put('user:' + u, '1', { metadata: { checked: wl?.updated || null } });
  const checked = known.metadata?.checked || wl?.updated;
  if (wl && !(body.refresh && minutesSince(checked) > 10)) return json({ state: 'ready', ...wl, checked });

  // Récupération de la watchlist par GitHub Actions, au plus une fois toutes les 3 min par pseudo
  if (!(await env.PUSH.get('pending:' + u))) {
    const go = await github(env)(`/actions/workflows/${USERS_WORKFLOW}/dispatches`, {
      method: 'POST',
      body: JSON.stringify({ ref: 'main', inputs: { user: u } }),
    });
    if (!go.ok) return wl ? json({ state: 'ready', ...wl, checked }) : json({ state: 'error', message: `GitHub ${go.status}` }, 502);
    await env.PUSH.put('pending:' + u, '1', { expirationTtl: 180 });
  }
  return json(wl ? { state: 'ready', refreshing: true, ...wl, checked } : { state: 'pending' });
}

// --- Web Push ------------------------------------------------------------------

async function push(path, req, env, origin, json) {
  if (!env.PUSH) return json({ ok: false, message: 'KV "PUSH" non lié au Worker' }, 500);
  const vapid = await vapidKeys(env);

  if (path === '/push/key' && req.method === 'GET') return json({ key: vapid.pub });
  if (req.method !== 'POST') return json({ ok: false, message: 'méthode refusée' }, 405);

  if (path === '/push/send') {
    if (!env.PUSH_SECRET || req.headers.get('Authorization') !== `Bearer ${env.PUSH_SECRET}`)
      return json({ ok: false, message: 'non autorisé' }, 401);
    const n = await req.json();
    const payload = { title: n.title || 'Watchlist au ciné', body: n.message || n.body || '', url: n.click || PAGE_URL };
    // Abonnés avec un autre pseudo : notif calculée avec LEUR watchlist et les films à l'affiche (n.films = [[slug, titre]])
    const showing = Array.isArray(n.films) ? n.films : null;
    const perUser = {};
    const payloadFor = async (user) => {
      if (!user || user === OWNER) return payload;
      if (!showing) return null;
      if (!(user in perUser)) {
        const wl = await env.PUSH.get('wl:' + user, 'json');
        if (!wl?.slugs) perUser[user] = null;
        else {
          const set = new Set(wl.slugs);
          const mine = [...new Set(showing.filter(([slug]) => set.has(slug)).map(([, title]) => title))];
          const click = `${PAGE_URL}?u=${encodeURIComponent(user)}`;
          perUser[user] = mine.length
            ? { title: `🎬 ${mine.length} film(s) de ta watchlist au ciné cette semaine`, body: mine.slice(0, 5).join(' · ') + (mine.length > 5 ? ' …' : ''), url: click }
            : { title: 'Rien de ta watchlist au ciné', body: 'Aucun film de ta watchlist ces 7 prochains jours.', url: click };
        }
      }
      return perUser[user];
    };
    let sent = 0, removed = 0, failed = 0, skipped = 0, cursor;
    do {
      const page = await env.PUSH.list({ prefix: 'sub:', cursor });
      for (const k of page.keys) {
        const sub = await env.PUSH.get(k.name, 'json');
        const p = sub && await payloadFor(sub.user);
        if (sub && !p) { skipped++; continue; }   // watchlist pas encore connue
        const r = sub ? await sendPush(sub, p, vapid) : { status: 410 };
        if (r.status === 404 || r.status === 410) { await env.PUSH.delete(k.name); removed++; }
        else if (r.ok) sent++;
        else failed++;
      }
      cursor = page.list_complete ? null : page.cursor;
    } while (cursor);
    return json({ ok: failed === 0, sent, removed, failed, skipped });
  }

  // Abonnement / désabonnement : seulement depuis la page
  if (!ALLOWED.includes(origin)) return json({ ok: false, message: 'origine refusée' }, 403);
  const body = await req.json();
  const endpoint = String(body?.endpoint || '');
  let host = '';
  try { const u = new URL(endpoint); if (u.protocol === 'https:') host = u.hostname; } catch {}
  if (!PUSH_HOSTS.test(host)) return json({ ok: false, message: 'abonnement invalide' }, 400);
  const key = 'sub:' + await sha256hex(endpoint);

  if (path === '/push/unsubscribe') { await env.PUSH.delete(key); return json({ ok: true }); }
  if (path === '/push/subscribe') {
    if (!body.keys?.p256dh || !body.keys?.auth) return json({ ok: false, message: 'clés manquantes' }, 400);
    const user = cleanUser(body.user);
    const sub = { endpoint, keys: { p256dh: body.keys.p256dh, auth: body.keys.auth }, ...(user && user !== OWNER ? { user } : {}) };
    const before = await env.PUSH.get(key);
    await env.PUSH.put(key, JSON.stringify(sub));
    if (before) return json({ ok: true, status: 200 });   // simple changement de pseudo : pas de nouvelle notif de bienvenue
    const r = await sendPush(sub, { title: 'Notifications activées', body: 'Tu seras prévenu quand des films de ta watchlist passent au ciné.', url: sub.user ? `${PAGE_URL}?u=${sub.user}` : PAGE_URL }, vapid);
    return json({ ok: r.ok, status: r.status });
  }
  return json({ ok: false, message: 'introuvable' }, 404);
}

const enc = new TextEncoder();
const b64u = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const unb64u = (s) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));
const concat = (...a) => { const out = new Uint8Array(a.reduce((n, x) => n + x.length, 0)); let i = 0; for (const x of a) { out.set(x, i); i += x.length; } return out; };
const sha256hex = async (s) => [...new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(s)))].map((b) => b.toString(16).padStart(2, '0')).join('');

// Paire de clés VAPID : créée une fois, gardée dans le KV (jamais dans le dépôt)
async function vapidKeys(env) {
  let v = await env.PUSH.get('vapid', 'json');
  if (!v) {
    const kp = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    v = { jwk: await crypto.subtle.exportKey('jwk', kp.privateKey), pub: b64u(await crypto.subtle.exportKey('raw', kp.publicKey)) };
    await env.PUSH.put('vapid', JSON.stringify(v));
  }
  if (!v.key) v.key = await crypto.subtle.importKey('jwk', v.jwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  return v;
}

// Jeton VAPID (RFC 8292) : JWT ES256 signé, valable 12 h
async function vapidAuth(endpoint, vapid) {
  const head = b64u(enc.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const claims = b64u(enc.encode(JSON.stringify({ aud: new URL(endpoint).origin, exp: Math.floor(Date.now() / 1e3) + 12 * 3600, sub: PAGE_URL })));
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, vapid.key, enc.encode(`${head}.${claims}`));
  return `vapid t=${head}.${claims}.${b64u(sig)}, k=${vapid.pub}`;
}

async function hkdf(salt, ikm, info, bytes) {
  const k = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, k, bytes * 8));
}

// Chiffrement du message (RFC 8291, aes128gcm) puis envoi au service de push du téléphone
async function sendPush(sub, payload, vapid) {
  const uaPub = unb64u(sub.keys.p256dh), auth = unb64u(sub.keys.auth);
  const eph = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const asPub = new Uint8Array(await crypto.subtle.exportKey('raw', eph.publicKey));
  const uaKey = await crypto.subtle.importKey('raw', uaPub, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, eph.privateKey, 256));

  const ikm = await hkdf(auth, shared, concat(enc.encode('WebPush: info\0'), uaPub, asPub), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, enc.encode('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdf(salt, ikm, enc.encode('Content-Encoding: nonce\0'), 12);
  const aes = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, aes, concat(enc.encode(JSON.stringify(payload)), new Uint8Array([2]))));

  const header = new Uint8Array(21);
  header.set(salt); new DataView(header.buffer).setUint32(16, 4096); header[20] = asPub.length;
  return fetch(sub.endpoint, {
    method: 'POST',
    headers: {
      'Authorization': await vapidAuth(sub.endpoint, vapid),
      'Content-Encoding': 'aes128gcm',
      'Content-Type': 'application/octet-stream',
      'TTL': String(3 * 86400),
      'Urgency': 'normal',
    },
    body: concat(header, asPub, cipher),
  });
}
