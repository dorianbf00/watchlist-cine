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

const REPO = 'dorianbf00/watchlist-cine';
const WORKFLOW = 'watchlist-cine.yml';
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

    const path = new URL(req.url).pathname.replace(/\/+$/, '');
    if (path.startsWith('/push')) {
      try { return await push(path, req, env, origin, json); }
      catch (e) { return json({ ok: false, message: String(e?.message || e) }, 500); }
    }

    if (req.method !== 'POST') return reply('error', { message: 'POST uniquement' }, 405);
    if (!ALLOWED.includes(origin)) return reply('error', { message: 'origine refusée' }, 403);

    const gh = (path, init = {}) => fetch(`https://api.github.com/repos/${REPO}${path}`, {
      ...init,
      headers: {
        'Authorization': `Bearer ${env.GITHUB_TOKEN}`,
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'watchlist-cine-refresh',
        ...(init.body ? { 'Content-Type': 'application/json' } : {}),
      },
    });

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
    let sent = 0, removed = 0, failed = 0, cursor;
    do {
      const page = await env.PUSH.list({ prefix: 'sub:', cursor });
      for (const k of page.keys) {
        const sub = await env.PUSH.get(k.name, 'json');
        const r = sub ? await sendPush(sub, payload, vapid) : { status: 410 };
        if (r.status === 404 || r.status === 410) { await env.PUSH.delete(k.name); removed++; }
        else if (r.ok) sent++;
        else failed++;
      }
      cursor = page.list_complete ? null : page.cursor;
    } while (cursor);
    return json({ ok: failed === 0, sent, removed, failed });
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
    const sub = { endpoint, keys: { p256dh: body.keys.p256dh, auth: body.keys.auth } };
    await env.PUSH.put(key, JSON.stringify(sub));
    const r = await sendPush(sub, { title: 'Notifications activées', body: 'Tu seras prévenu quand des films de ta watchlist passent au ciné.', url: PAGE_URL }, vapid);
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
