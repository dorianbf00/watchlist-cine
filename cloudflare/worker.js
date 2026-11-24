// Relais "tirer pour actualiser" — Cloudflare Worker (gratuit)
// La page publique appelle ce relais ; lui seul détient le token GitHub (secret GITHUB_TOKEN du Worker)
// et lance le workflow "Watchlist au cinéma" (workflow_dispatch). Au plus une relance toutes les 10 min.
//
// Réponse JSON { state } :
//   started : relance lancée            running : une mise à jour tourne déjà
//   fresh   : dernière mise à jour il y a moins de 10 min (rien à faire, la page est à jour)
//   error   : souci côté GitHub (token expiré, etc.)

const REPO = 'dorianbf00/watchlist-cine';
const WORKFLOW = 'watchlist-cine.yml';
const COOLDOWN_MIN = 10;
const ALLOWED = ['https://dorianbf00.github.io', 'http://localhost:8080'];

export default {
  async fetch(req, env) {
    const origin = req.headers.get('Origin') || '';
    const cors = {
      'Access-Control-Allow-Origin': ALLOWED.includes(origin) ? origin : ALLOWED[0],
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Vary': 'Origin',
    };
    const reply = (state, extra = {}, status = 200) =>
      new Response(JSON.stringify({ state, ...extra }), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

    if (req.method === 'OPTIONS') return new Response(null, { headers: cors });
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
