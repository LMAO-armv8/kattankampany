#!/usr/bin/env node
/**
 * KK cache warmer (GitHub Actions) — multi-country Worker edge warm
 * =============================================================================
 * Warms the Cloudflare Worker HTML cache (`x-kk-html-cache`).
 *
 * Worker v4+ keys HTML by PRICING ZONE REP (not every country):
 *   NG/KE → FJ, FR → DE, BR → ZA, etc. So `--countries zones` (35 reps)
 *   warms prices for ~250 countries. Requires Worker CACHE_VERSION >= 4.
 *
 * IMPORTANT — Workers Cache API is PER CLOUDFLARE COLO, not global:
 *   This Action warms the colo that GitHub’s runner hits (usually US).
 *   Enable Tiered Cache (Smart) + Cache Reserve so other regions benefit.
 *   Origin LiteSpeed also only needs the 35 zone-rep cookies now.
 *
 * Phase 1: BFS crawl → discover URLs (always sends Cookie: default country).
 * Phase 2: re-fetch every URL × each country.
 * Confirm: after each MISS, immediately re-fetch once — expect HIT + put=ok.
 * Verify:  optional final pass; exit non-zero if HIT rate is bad.
 *
 * Usage:
 *   node kk-cache-warm.js --countries zones --verify
 *   node kk-cache-warm.js --countries kk --concurrency 2
 *   node kk-cache-warm.js --countries IN,US,GB,AE --confirm
 */

'use strict';

// ---- config ----------------------------------------------------------------
const argv = process.argv.slice(2);
const opt = (name, def) => {
  const i = argv.indexOf('--' + name);
  if (i === -1) return def;
  const v = argv[i + 1];
  return v && !v.startsWith('--') ? v : true;
};
const BASE = argv.find((a) => /^https?:\/\//.test(a)) || 'https://kattankampany.com/';
const ORIGIN = new URL(BASE).origin;
const HOST = new URL(BASE).host;

const CONCURRENCY = parseInt(opt('concurrency', '2'), 10);
const DELAY_MS = parseInt(opt('delay', '600'), 10);
const REQUEST_TIMEOUT = parseInt(opt('timeout', '45000'), 10);
const MAX_RETRIES = parseInt(opt('retries', '4'), 10);
const MAX_PAGES = parseInt(opt('max', '5000'), 10);
const USE_SITEMAP = !!opt('sitemap', false);
const VERIFY = !!opt('verify', false);
// After every Worker MISS, re-fetch once to prove cache.put stuck (default ON for Actions).
const CONFIRM = opt('confirm', true) !== '0' && opt('confirm', true) !== 'false' && !!opt('confirm', true);
const FAIL_UNDER = parseFloat(opt('fail-under', '0.5')); // verify HIT ratio below this → exit 1
const DEFAULT_COUNTRY = String(opt('default-country', 'IN')).toUpperCase();
const COUNTRIES_ARG = opt('countries', false);
const UA = 'KK-CacheWarmer/1.4 (+github-actions; cache warmup)';

const POPULAR = ['IN', 'US', 'GB', 'CA', 'AU', 'SG', 'DE', 'AE', 'QA', 'SA', 'CH'];

const KK_LIST = [
  'CA', 'IN', 'US', 'GB', 'DE', 'AU', 'NL', 'AE', 'SA', 'SG', 'QA', 'OM', 'BH', 'JO', 'KW', 'MY',
  'NZ', 'SE', 'FR', 'AT', 'CZ', 'PL', 'CH', 'MT', 'HU', 'JP', 'ZA', 'IE', 'FI', 'ID', 'HR', 'ES',
  'PT', 'IT', 'NO', 'DK', 'BE', 'TH', 'FJ', 'MV', 'GP', 'RE',
];

/** One representative country per WCPBC pricing zone. */
const ZONE_REPS = [
  'IN', 'CA', 'US', 'GB', 'AE', 'QA', 'SA', 'AU', 'SG', 'BH', 'MY', 'NZ', 'OM', 'KW',
  'GP', 'MV', 'CZ', 'SE', 'NO', 'JP', 'PL', 'DK', 'HU', 'TH', 'CN', 'JO', 'ID', 'PG',
  'BG', 'MX', 'ZA', 'FJ', 'DE', 'CH', 'AX',
];

const ALL_FALLBACK = ['IN', 'US', 'GB', 'CA', 'AU', 'SG', 'DE', 'AE', 'QA', 'SA', 'CH', 'AF', 'AL', 'DZ', 'AS', 'AD', 'AO', 'AI', 'AQ', 'AG', 'AR', 'AM', 'AW', 'AT', 'AZ', 'BS', 'BH', 'BD', 'BB', 'BY', 'PW', 'BE', 'BZ', 'BJ', 'BM', 'BT', 'BO', 'BQ', 'BA', 'BW', 'BV', 'BR', 'IO', 'BN', 'BG', 'BF', 'BI', 'KH', 'CM', 'CV', 'KY', 'CF', 'TD', 'CL', 'CN', 'CX', 'CC', 'CO', 'KM', 'CG', 'CD', 'CK', 'CR', 'HR', 'CU', 'CW', 'CY', 'CZ', 'DK', 'DJ', 'DM', 'DO', 'EC', 'EG', 'SV', 'GQ', 'ER', 'EE', 'SZ', 'ET', 'FK', 'FO', 'FJ', 'FI', 'FR', 'GF', 'PF', 'TF', 'GA', 'GM', 'GE', 'GH', 'GI', 'GR', 'GL', 'GD', 'GP', 'GU', 'GT', 'GG', 'GN', 'GW', 'GY', 'HT', 'HM', 'HN', 'HK', 'HU', 'IS', 'ID', 'IR', 'IQ', 'IE', 'IM', 'IL', 'IT', 'CI', 'JM', 'JP', 'JE', 'JO', 'KZ', 'KE', 'KI', 'XK', 'KW', 'KG', 'LA', 'LV', 'LB', 'LS', 'LR', 'LY', 'LI', 'LT', 'LU', 'MO', 'MG', 'MW', 'MY', 'MV', 'ML', 'MT', 'MH', 'MQ', 'MR', 'MU', 'YT', 'MX', 'FM', 'MD', 'MC', 'MN', 'ME', 'MS', 'MA', 'MZ', 'MM', 'NA', 'NR', 'NP', 'NL', 'NC', 'NZ', 'NI', 'NE', 'NG', 'NU', 'NF', 'KP', 'MK', 'MP', 'NO', 'OM', 'PK', 'PS', 'PA', 'PG', 'PY', 'PE', 'PH', 'PN', 'PL', 'PT', 'PR', 'RE', 'RO', 'RU', 'RW', 'ST', 'BL', 'SH', 'KN', 'LC', 'SX', 'MF', 'PM', 'VC', 'WS', 'SM', 'SN', 'RS', 'SC', 'SL', 'SK', 'SI', 'SB', 'SO', 'ZA', 'GS', 'KR', 'SS', 'ES', 'LK', 'SD', 'SR', 'SJ', 'SE', 'SY', 'TW', 'TJ', 'TZ', 'TH', 'TL', 'TG', 'TK', 'TO', 'TT', 'TN', 'TM', 'TC', 'TV', 'TR', 'UG', 'UA', 'UM', 'UY', 'UZ', 'VU', 'VA', 'VE', 'VN', 'VG', 'VI', 'WF', 'EH', 'YE', 'ZM', 'ZW', 'AX'];

const SKIP_PATH = /(^\/wp-admin\/|^\/wp-login\.php|^\/xmlrpc\.php|\/wp-json\/|^\/wp-cron\.php|^\/cart\/?|^\/checkout\/?|^\/my-account\/?|^\/user\/|\/wc-api\/|\/wp-content\/|\/wp-includes\/|\/feed\/?$|\/comment-page-|\/oembed\/|\/trackback\/?$)/i;
const SKIP_EXT = /\.(css|js|mjs|map|jpe?g|png|gif|webp|avif|svg|ico|woff2?|ttf|eot|pdf|zip|mp4|webm|m4s|ts|m3u8|xml|json|txt|rss)(\?|#|$)/i;

// ---- state -----------------------------------------------------------------
const visited = new Set();
const queue = [];
let discoveredCountries = null;

function normalize(href, from) {
  let u;
  try { u = new URL(href, from); } catch { return null; }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  if (u.host !== HOST) return null;
  if (/%7B|%7D|%5B|%5D|\{|\}|\[|\]/i.test(u.pathname)) return null;
  u.hash = '';
  u.search = '';
  let out = u.href;
  if (!/\.[a-z0-9]{2,5}$/i.test(u.pathname) && !out.endsWith('/')) out += '/';
  return out;
}
function shouldCrawl(url) {
  const path = new URL(url).pathname;
  return !SKIP_PATH.test(path) && !SKIP_EXT.test(url);
}
function enqueue(url) {
  if (!url || visited.has(url) || !shouldCrawl(url)) return;
  if (visited.size + queue.length >= MAX_PAGES) return;
  visited.add(url);
  queue.push(url);
}

const LINK_RE = /(?:href|src)\s*=\s*["']([^"'#][^"']*)["']/gi;
function extractLinks(html, from) {
  const out = [];
  let m;
  while ((m = LINK_RE.exec(html)) !== null) {
    const n = normalize(m[1], from);
    if (n) out.push(n);
  }
  return out;
}
function extractCountries(html) {
  const sel = html.match(/class="[^"]*wcpbc-country-switcher[^"]*"[\s\S]*?<\/select>/i);
  if (!sel) return null;
  const codes = [...sel[0].matchAll(/<option[^>]*\bvalue="([A-Z]{2})"/gi)].map((m) => m[1]);
  return codes.length ? [...new Set(codes)] : null;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let pausedUntil = 0;
function pauseAll(ms) { pausedUntil = Math.max(pausedUntil, Date.now() + ms); }
async function waitIfPaused() { const d = pausedUntil - Date.now(); if (d > 0) await sleep(d); }
const OVERLOAD = new Set([429, 500, 502, 503, 504, 508, 520, 521, 522, 523, 524]);

async function fetchOnce(url, country) {
  const headers = {
    Accept: 'text/html,application/xhtml+xml',
    'User-Agent': UA,
    // Force HTML Accept so the Worker HTML path runs (not asset passthrough).
    'Accept-Language': 'en-US,en;q=0.9',
  };
  // Always send a country cookie so Actions' US IP doesn't key everything as US.
  const cc = (country || DEFAULT_COUNTRY || 'IN').toUpperCase();
  if (/^[A-Z]{2}$/.test(cc)) headers.Cookie = 'kk_wcpbc_country=' + cc;

  for (let attempt = 0; ; attempt++) {
    await waitIfPaused();
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), REQUEST_TIMEOUT);
    const t0 = Date.now();
    try {
      const res = await fetch(url, { redirect: 'follow', headers, signal: ctrl.signal });
      clearTimeout(timer);
      const ms = Date.now() - t0;

      if (OVERLOAD.has(res.status)) {
        const ra = parseInt(res.headers.get('retry-after') || '0', 10);
        const backoff = ra > 0 ? ra * 1000 : Math.min(60000, 4000 * Math.pow(2, attempt));
        pauseAll(backoff);
        console.log(`  ⚠ ${res.status} overload on ${new URL(url).pathname} — backing off ${Math.round(backoff / 1000)}s`);
        if (attempt < MAX_RETRIES) { await sleep(backoff); continue; }
        return emptyResult(ms, res.status, true);
      }

      // x-kk-html-cache = Worker edge HTML cache (what visitors get).
      // x-kk-html-cache-put = whether MISS successfully stored (Worker v3+).
      // cf-cache-status is NOT the country HTML cache — ignore for hit-rate.
      const kk = res.headers.get('x-kk-html-cache') || '-';
      const put = (res.headers.get('x-kk-html-cache-put') || '-').toLowerCase();
      const putErr = res.headers.get('x-kk-html-cache-put-error') || '';
      const geo = res.headers.get('x-kk-html-country') || '-';
      const zone = res.headers.get('x-kk-html-zone') || '-';
      const cf = res.headers.get('cf-cache-status') || '-';
      const ls = res.headers.get('x-litespeed-cache') || '-';
      const ct = res.headers.get('content-type') || '';
      let html = '';
      if (ct.includes('text/html')) html = await res.text();
      else {
        // Non-HTML: Worker bypassed — drain body so sockets close cleanly.
        try { await res.arrayBuffer(); } catch { /* ignore */ }
      }
      return {
        ms, status: res.status, ls, kk, put, putErr, geo, zone, cf,
        redirected: res.redirected, html, overloaded: false, country: cc,
      };
    } catch (e) {
      clearTimeout(timer);
      const backoff = Math.min(60000, 4000 * Math.pow(2, attempt));
      if (attempt < MAX_RETRIES) {
        console.log(`  ⚠ ${e.name === 'AbortError' ? 'timeout' : e.message} on ${new URL(url).pathname} — retry in ${Math.round(backoff / 1000)}s`);
        pauseAll(backoff);
        await sleep(backoff);
        continue;
      }
      throw e;
    }
  }
}

function emptyResult(ms, status, overloaded) {
  return {
    ms, status, ls: '-', kk: '-', put: '-', putErr: '', geo: '-', cf: '-',
    redirected: false, html: '', overloaded: !!overloaded, country: '',
  };
}

/**
 * Fetch once; if Worker MISS, immediately fetch again to confirm put stuck.
 * Returns stats flags for aggregators.
 */
async function warmOnce(url, country) {
  const r1 = await fetchOnce(url, country);
  const out = {
    r1,
    r2: null,
    hit: /hit/i.test(r1.kk),
    miss: /miss/i.test(r1.kk),
    putOk: r1.put === 'ok',
    putFail: r1.put === 'fail',
    confirmed: /hit/i.test(r1.kk),
    confirmMiss: false,
    noWorker: r1.kk === '-',
  };

  if (!CONFIRM || !out.miss || r1.overloaded) return out;

  // Brief pause so Cache API put is visible to the next match in this colo.
  await sleep(80);
  const r2 = await fetchOnce(url, country);
  out.r2 = r2;
  out.confirmed = /hit/i.test(r2.kk);
  out.confirmMiss = /miss/i.test(r2.kk);
  if (r2.put === 'ok') out.putOk = true;
  if (r2.put === 'fail') out.putFail = true;
  return out;
}

async function pool(items, worker) {
  let idx = 0;
  const runners = Array.from({ length: CONCURRENCY }, async () => {
    while (idx < items.length) {
      const i = idx++;
      await worker(items[i], i);
      if (DELAY_MS) await sleep(DELAY_MS);
    }
  });
  await Promise.all(runners);
}

async function seedSitemap() {
  for (const c of ['/sitemap_index.xml', '/sitemap.xml', '/wp-sitemap.xml']) {
    try {
      const res = await fetch(ORIGIN + c, { headers: { 'User-Agent': UA } });
      if (!res.ok) continue;
      const xml = await res.text();
      for (const m of xml.matchAll(/<loc>\s*([^<\s]+)\s*<\/loc>/gi)) {
        const loc = m[1];
        if (/\.xml(\?|$)/i.test(loc)) {
          try {
            const x2 = await (await fetch(loc, { headers: { 'User-Agent': UA } })).text();
            for (const m2 of x2.matchAll(/<loc>\s*([^<\s]+)\s*<\/loc>/gi)) enqueue(normalize(m2[1], ORIGIN));
          } catch { /* ignore nested sitemap errors */ }
        } else {
          enqueue(normalize(loc, ORIGIN));
        }
      }
      console.log(`Seeded ${visited.size} URLs from ${c}`);
      return;
    } catch { /* try next */ }
  }
  console.log('No sitemap found; relying on link crawl.');
}

// ---- phase 1: crawl + discover (default country cookie) --------------------
async function crawl() {
  const s = {
    fetched: 0, hitKK: 0, missKK: 0, putOk: 0, putFail: 0,
    confirmed: 0, confirmMiss: 0, noWorker: 0, errors: 0, ms: 0,
  };
  const drain = async () => {
    const runners = Array.from({ length: CONCURRENCY }, async () => {
      while (queue.length) {
        const url = queue.shift();
        try {
          const w = await warmOnce(url, DEFAULT_COUNTRY);
          const r = w.r1;
          s.fetched++; s.ms += r.ms;
          if (w.hit) s.hitKK++;
          if (w.miss) s.missKK++;
          if (w.putOk) s.putOk++;
          if (w.putFail) s.putFail++;
          if (w.miss && w.confirmed) s.confirmed++;
          if (w.confirmMiss) s.confirmMiss++;
          if (w.noWorker) s.noWorker++;
          if (!discoveredCountries && r.html) discoveredCountries = extractCountries(r.html);
          let links = 0;
          if (r.html) {
            const found = extractLinks(r.html, url);
            for (const l of found) enqueue(l);
            links = found.length;
          }
          const put = w.miss ? (w.putFail ? 'put=FAIL' : w.confirmed ? 'put=ok→HIT' : w.putOk ? 'put=ok' : 'put=?') : '';
          console.log(
            `[${s.fetched}] ${String(r.ms).padStart(5)}ms KK=${r.kk.padEnd(6)} ${put.padEnd(10)} ${r.status}  +${links}  ${new URL(url).pathname}`
          );
          if (w.putFail) {
            console.log(`  ✗ cache.put FAILED — deploy Worker v3+ (${r.putErr || 'no error detail'})`);
          }
          if (w.confirmMiss) {
            console.log(`  ✗ MISS then still MISS — edge is NOT storing (Worker/Vary/TTL bug or logged-in bypass)`);
          }
        } catch (e) {
          s.errors++;
          console.log(`[ERR] ${url}  ${e.message}`);
        }
        if (DELAY_MS) await sleep(DELAY_MS);
      }
    });
    await Promise.all(runners);
  };
  await drain();
  return s;
}

// ---- phase 2: warm each country --------------------------------------------
async function warmCountries(countries, urls) {
  console.log(`\n──────── PHASE 2: warming ${countries.length} countries × ${urls.length} URLs ────────`);
  console.log('(after each MISS we re-fetch once to confirm the Worker stored the page)\n');
  const grand = {
    req: 0, hitKK: 0, missKK: 0, putOk: 0, putFail: 0,
    confirmed: 0, confirmMiss: 0, noWorker: 0, errors: 0,
  };

  for (let ci = 0; ci < countries.length; ci++) {
    const cc = countries[ci];
    const s = {
      hitKK: 0, missKK: 0, putOk: 0, putFail: 0,
      confirmed: 0, confirmMiss: 0, noWorker: 0, errors: 0, ms: 0, n: 0,
    };
    const tStart = Date.now();
    await pool(urls, async (url) => {
      try {
        const w = await warmOnce(url, cc);
        s.n++; s.ms += w.r1.ms + (w.r2 ? w.r2.ms : 0);
        if (w.hit) s.hitKK++;
        if (w.miss) s.missKK++;
        if (w.putOk) s.putOk++;
        if (w.putFail) s.putFail++;
        if (w.miss && w.confirmed) s.confirmed++;
        if (w.confirmMiss) s.confirmMiss++;
        if (w.noWorker) s.noWorker++;
      } catch {
        s.errors++;
      }
      if (s.n % 10 === 0 || s.n === urls.length) {
        process.stdout.write(
          `\r  [${ci + 1}/${countries.length}] ${cc}  ${s.n}/${urls.length}  hit ${s.hitKK} miss ${s.missKK} confirm ${s.confirmed} putFail ${s.putFail}   `
        );
      }
    });
    grand.req += s.n;
    grand.hitKK += s.hitKK;
    grand.missKK += s.missKK;
    grand.putOk += s.putOk;
    grand.putFail += s.putFail;
    grand.confirmed += s.confirmed;
    grand.confirmMiss += s.confirmMiss;
    grand.noWorker += s.noWorker;
    grand.errors += s.errors;
    const secs = ((Date.now() - tStart) / 1000).toFixed(0);
    process.stdout.write(
      `\r  [${ci + 1}/${countries.length}] ${cc}: ${s.n}p  HIT ${s.hitKK} MISS ${s.missKK}  storedOK ${s.confirmed}  putFail ${s.putFail}  noHdr ${s.noWorker}  avg ${s.n ? Math.round(s.ms / s.n) : 0}ms  (${secs}s)\n`
    );
  }

  console.log('\nPHASE 2 TOTAL');
  console.log(`  requests:     ${grand.req}`);
  console.log(`  Worker HIT:   ${grand.hitKK}`);
  console.log(`  Worker MISS:  ${grand.missKK}`);
  console.log(`  MISS→HIT ok:  ${grand.confirmed}  (edge store working in this colo)`);
  console.log(`  MISS→MISS:    ${grand.confirmMiss}  (edge NOT storing — deploy Worker v3)`);
  console.log(`  put=fail hdr: ${grand.putFail}`);
  console.log(`  no x-kk hdr:  ${grand.noWorker}  (Worker route missing / non-HTML)`);
  console.log(`  errors:       ${grand.errors}`);
  return grand;
}

function resolveCountries() {
  if (!COUNTRIES_ARG) return null;
  if (COUNTRIES_ARG === 'zones' || COUNTRIES_ARG === 'zone') {
    console.log(`Countries: ${ZONE_REPS.length} (1 per WCPBC pricing zone)`);
    return ZONE_REPS.slice();
  }
  if (COUNTRIES_ARG === 'kk' || COUNTRIES_ARG === 'markets') {
    console.log(`Countries: ${KK_LIST.length} (KK shipping markets)`);
    return KK_LIST.slice();
  }
  if (COUNTRIES_ARG === 'popular') {
    console.log(`Countries: ${POPULAR.length} (popular preset)`);
    return POPULAR.slice();
  }
  if (COUNTRIES_ARG === true || COUNTRIES_ARG === 'all') {
    const list = discoveredCountries && discoveredCountries.length ? discoveredCountries : ALL_FALLBACK;
    console.log(`Countries: ${list.length} (${discoveredCountries ? 'from switcher' : 'from fallback list'})`);
    return list.slice();
  }
  const list = String(COUNTRIES_ARG).toUpperCase().split(',').map((c) => c.trim()).filter((c) => /^[A-Z]{2}$/.test(c));
  console.log(`Countries: ${list.length} (explicit list)`);
  return list;
}

// ---- run -------------------------------------------------------------------
(async () => {
  console.log(`Warming ${ORIGIN}`);
  console.log(`  concurrency=${CONCURRENCY} max=${MAX_PAGES} default-country=${DEFAULT_COUNTRY}`);
  console.log(`  confirm-after-miss=${CONFIRM} verify=${VERIFY}`);
  console.log('');
  console.log('NOTE: Worker cache is per Cloudflare colo. This Action warms the runner’s colo.');
  console.log('      Enable Cloudflare Tiered Cache (Smart) + Cache Reserve so other regions benefit.');
  console.log('      Deploy Worker v3+ first (fixes max-age=0 / Vary: Cookie so puts stick).');
  console.log('');

  if (USE_SITEMAP) await seedSitemap();
  enqueue(normalize(BASE, BASE));

  const start = Date.now();
  const s1 = await crawl();
  const urls = [...visited].filter(shouldCrawl);

  console.log('\n──────── PHASE 1 (discover + default country) ────────');
  console.log(`pages: ${s1.fetched}  HIT ${s1.hitKK}/MISS ${s1.missKK}  MISS→HIT ${s1.confirmed}  putFail ${s1.putFail}  noHdr ${s1.noWorker}  errors ${s1.errors}`);
  console.log(`avg ${s1.fetched ? Math.round(s1.ms / s1.fetched) : 0}ms`);

  let phase2 = null;
  const countries = resolveCountries();
  if (countries && countries.length) {
    phase2 = await warmCountries(countries, urls);
  }

  let verifyHitRatio = 1;
  if (VERIFY && urls.length) {
    const verifyCountries = countries && countries.length
      ? countries.slice(0, Math.min(countries.length, 5)) // sample first 5 zones
      : [DEFAULT_COUNTRY];
    console.log(`\n──────── VERIFY (expect HIT in this colo) × ${verifyCountries.join(',')} ────────`);
    let hit = 0, miss = 0, n = 0, ms = 0;
    for (const cc of verifyCountries) {
      await pool(urls, async (url) => {
        try {
          const r = await fetchOnce(url, cc);
          n++; ms += r.ms;
          if (/hit/i.test(r.kk)) hit++;
          else if (/miss/i.test(r.kk)) miss++;
        } catch { /* ignore */ }
      });
      console.log(`  ${cc}: running…`);
    }
    verifyHitRatio = n ? hit / n : 0;
    console.log(`verify: ${n} fetches, HIT ${hit}/MISS ${miss} (${(verifyHitRatio * 100).toFixed(1)}%), avg ${n ? Math.round(ms / n) : 0}ms`);
  }

  console.log(`\nTotal URLs: ${urls.length}   Time: ${((Date.now() - start) / 1000).toFixed(1)}s`);

  // Exit non-zero so Actions shows red when the edge is not storing.
  const putBroken = (s1.putFail > 0) || (phase2 && phase2.putFail > 0);
  const confirmBroken = (s1.confirmMiss > 3) || (phase2 && phase2.confirmMiss > Math.max(5, (phase2.missKK || 0) * 0.2));
  const verifyBroken = VERIFY && verifyHitRatio < FAIL_UNDER;
  const noHdrBroken = s1.noWorker > s1.fetched * 0.5;

  if (putBroken || confirmBroken || verifyBroken || noHdrBroken) {
    console.error('\n✗ WARM FAILED HEALTH CHECK');
    if (noHdrBroken) console.error('  - Most responses lack x-kk-html-cache → Worker route not hitting HTML');
    if (putBroken) console.error('  - x-kk-html-cache-put: fail → deploy Worker v3 from strategy-B/cloudflare-worker.js');
    if (confirmBroken) console.error('  - MISS then still MISS → edge store broken (Vary/TTL) or private session');
    if (verifyBroken) console.error(`  - Verify HIT ratio ${(verifyHitRatio * 100).toFixed(1)}% < ${(FAIL_UNDER * 100).toFixed(0)}%`);
    process.exit(1);
  }

  console.log('\n✓ Warm finished (this colo). Other regions still need Tiered Cache / Cache Reserve / first visitor.');
})();
