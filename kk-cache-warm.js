#!/usr/bin/env node
/**
 * KK cache warmer (multi-country)
 * =============================================================================
 * Phase 1: BFS-crawl internal links from the homepage, dedupe with a Set, and
 *          fetch each unique page once (guest) — discovers the full URL list and
 *          warms the default variant.
 * Phase 2 (optional, --countries): re-fetch every discovered URL once per
 *          country, sending `kk_wcpbc_country=<CC>` — the cookie the LiteSpeed
 *          Vary + Cloudflare worker key the cache on — so every country's price
 *          variant is warmed too.
 *
 * Node 18+ (built-in fetch). No dependencies.
 *
 * Usage:
 *   node kk-cache-warm.js                        # crawl + warm default country only
 *   node kk-cache-warm.js --countries            # + warm ALL countries (from the switcher)
 *   node kk-cache-warm.js --countries all        # same as above
 *   node kk-cache-warm.js --countries popular     # only the "Popular destinations" set
 *   node kk-cache-warm.js --countries IN,US,GB,AE # only these
 *   node kk-cache-warm.js --countries all --concurrency 10 --max 4000
 *   node kk-cache-warm.js --verify                # re-fetch default set, report hit-rate
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
const CONCURRENCY = parseInt(opt('concurrency', '6'), 10);
const DELAY_MS = parseInt(opt('delay', '0'), 10);
const MAX_PAGES = parseInt(opt('max', '5000'), 10);
const USE_SITEMAP = !!opt('sitemap', false);
const VERIFY = !!opt('verify', false);
const COUNTRIES_ARG = opt('countries', false); // false | true | 'all' | 'popular' | 'IN,US,...'
const UA = 'KK-CacheWarmer/1.1 (+cache warmup)';

const POPULAR = ['IN', 'US', 'GB', 'CA', 'AU', 'SG', 'DE', 'AE', 'QA', 'SA', 'CH'];

// Full ISO-3166 alpha-2 list from the WCPBC country switcher (fallback if the
// live switcher can't be parsed).
const ALL_FALLBACK = ['IN','US','GB','CA','AU','SG','DE','AE','QA','SA','CH','AF','AL','DZ','AS','AD','AO','AI','AQ','AG','AR','AM','AW','AT','AZ','BS','BH','BD','BB','BY','PW','BE','BZ','BJ','BM','BT','BO','BQ','BA','BW','BV','BR','IO','BN','BG','BF','BI','KH','CM','CV','KY','CF','TD','CL','CN','CX','CC','CO','KM','CG','CD','CK','CR','HR','CU','CW','CY','CZ','DK','DJ','DM','DO','EC','EG','SV','GQ','ER','EE','SZ','ET','FK','FO','FJ','FI','FR','GF','PF','TF','GA','GM','GE','GH','GI','GR','GL','GD','GP','GU','GT','GG','GN','GW','GY','HT','HM','HN','HK','HU','IS','ID','IR','IQ','IE','IM','IL','IT','CI','JM','JP','JE','JO','KZ','KE','KI','XK','KW','KG','LA','LV','LB','LS','LR','LY','LI','LT','LU','MO','MG','MW','MY','MV','ML','MT','MH','MQ','MR','MU','YT','MX','FM','MD','MC','MN','ME','MS','MA','MZ','MM','NA','NR','NP','NL','NC','NZ','NI','NE','NG','NU','NF','KP','MK','MP','NO','OM','PK','PS','PA','PG','PY','PE','PH','PN','PL','PT','PR','RE','RO','RU','RW','ST','BL','SH','KN','LC','SX','MF','PM','VC','WS','SM','SN','RS','SC','SL','SK','SI','SB','SO','ZA','GS','KR','SS','ES','LK','SD','SR','SJ','SE','SY','TW','TJ','TZ','TH','TL','TG','TK','TO','TT','TN','TM','TC','TV','TR','UG','UA','UM','UY','UZ','VU','VA','VE','VN','VG','VI','WF','EH','YE','ZM','ZW','AX'];

// Paths we never crawl (dynamic / private / assets).
const SKIP_PATH = /(^\/wp-admin\/|^\/wp-login\.php|^\/xmlrpc\.php|\/wp-json\/|^\/wp-cron\.php|^\/cart\/?|^\/checkout\/?|^\/my-account\/?|^\/user\/|\/wc-api\/|\/wp-content\/|\/wp-includes\/|\/feed\/?$|\/comment-page-|\/oembed\/|\/trackback\/?$)/i;
const SKIP_EXT = /\.(css|js|mjs|map|jpe?g|png|gif|webp|avif|svg|ico|woff2?|ttf|eot|pdf|zip|mp4|webm|m4s|ts|m3u8|xml|json|txt|rss)(\?|#|$)/i;

// ---- state -----------------------------------------------------------------
const visited = new Set();
const queue = [];
let discoveredCountries = null; // filled from the switcher on first HTML page

function normalize(href, from) {
  let u;
  try { u = new URL(href, from); } catch { return null; }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  if (u.host !== HOST) return null;
  if (/%7B|%7D|%5B|%5D|\{|\}|\[|\]/i.test(u.pathname)) return null; // template placeholders
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
// Pull country codes out of the WCPBC country switcher <select>.
function extractCountries(html) {
  const sel = html.match(/class="[^"]*wcpbc-country-switcher[^"]*"[\s\S]*?<\/select>/i);
  if (!sel) return null;
  const codes = [...sel[0].matchAll(/<option[^>]*\bvalue="([A-Z]{2})"/gi)].map((m) => m[1]);
  return codes.length ? [...new Set(codes)] : null;
}

async function fetchOnce(url, country) {
  const headers = { Accept: 'text/html,application/xhtml+xml', 'User-Agent': UA };
  if (country) headers.Cookie = 'kk_wcpbc_country=' + country;
  const t0 = Date.now();
  const res = await fetch(url, { redirect: 'follow', headers });
  const ms = Date.now() - t0;
  // NOTE: through the Cloudflare Worker, `x-litespeed-cache` is a STALE header
  // replayed from the Worker's cached copy — it does not reflect LiteSpeed's live
  // state. `x-kk-html-cache` (the Worker's own HIT/MISS) is the meaningful one.
  const kk = res.headers.get('x-kk-html-cache') || '-';
  const cf = res.headers.get('cf-cache-status') || '-';
  const ls = res.headers.get('x-litespeed-cache') || '-';
  const ct = res.headers.get('content-type') || '';
  let html = '';
  if (ct.includes('text/html')) html = await res.text();
  return { ms, status: res.status, ls, kk, cf, redirected: res.redirected, html };
}

// Generic bounded worker pool over an array of jobs.
async function pool(items, worker) {
  let idx = 0;
  const runners = Array.from({ length: CONCURRENCY }, async () => {
    while (idx < items.length) {
      const i = idx++;
      await worker(items[i], i);
      if (DELAY_MS) await new Promise((r) => setTimeout(r, DELAY_MS));
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
          } catch {}
        } else {
          enqueue(normalize(loc, ORIGIN));
        }
      }
      console.log(`Seeded ${visited.size} URLs from ${c}`);
      return;
    } catch {}
  }
  console.log('No sitemap found; relying on link crawl.');
}

// ---- phase 1: crawl + discover ---------------------------------------------
async function crawl() {
  const s = { fetched: 0, hitKK: 0, missKK: 0, hitCF: 0, errors: 0, ms: 0 };
  const drain = async () => {
    const runners = Array.from({ length: CONCURRENCY }, async () => {
      while (queue.length) {
        const url = queue.shift();
        try {
          const r = await fetchOnce(url);
          s.fetched++; s.ms += r.ms;
          if (/hit/i.test(r.kk)) s.hitKK++; else if (/miss/i.test(r.kk)) s.missKK++;
          if (/hit/i.test(r.cf)) s.hitCF++;
          if (!discoveredCountries && r.html) discoveredCountries = extractCountries(r.html);
          let links = 0;
          if (r.html) { const f = extractLinks(r.html, url); for (const l of f) enqueue(l); links = f.length; }
          console.log(`[${s.fetched}] ${String(r.ms).padStart(5)}ms KK=${r.kk.padEnd(6)} CF=${r.cf.padEnd(7)} ${r.status}  +${links}  ${new URL(url).pathname}`);
        } catch (e) { s.errors++; console.log(`[ERR] ${url}  ${e.message}`); }
        if (DELAY_MS) await new Promise((r) => setTimeout(r, DELAY_MS));
      }
    });
    await Promise.all(runners);
  };
  await drain();
  return s;
}

// ---- phase 2: warm each country --------------------------------------------
async function warmCountries(countries, urls) {
  console.log(`\n──────── PHASE 2: warming ${countries.length} countries × ${urls.length} URLs = ${countries.length * urls.length} requests ────────`);
  const grand = { req: 0, hitKK: 0, missKK: 0, hitCF: 0, errors: 0 };
  for (let ci = 0; ci < countries.length; ci++) {
    const cc = countries[ci];
    const s = { hitKK: 0, missKK: 0, hitCF: 0, errors: 0, ms: 0, n: 0 };
    const tStart = Date.now();
    await pool(urls, async (url) => {
      try {
        const r = await fetchOnce(url, cc);
        s.n++; s.ms += r.ms;
        if (/hit/i.test(r.kk)) s.hitKK++; else if (/miss/i.test(r.kk)) s.missKK++;
        if (/hit/i.test(r.cf)) s.hitCF++;
      } catch { s.errors++; }
      // live progress so it never looks frozen
      if (s.n % 10 === 0 || s.n === urls.length) {
        process.stdout.write(`\r  [${ci + 1}/${countries.length}] ${cc}  ${s.n}/${urls.length}  hit ${s.hitKK} miss ${s.missKK}      `);
      }
    });
    grand.req += s.n; grand.hitKK += s.hitKK; grand.missKK += s.missKK; grand.hitCF += s.hitCF; grand.errors += s.errors;
    const secs = ((Date.now() - tStart) / 1000).toFixed(0);
    process.stdout.write(`\r  [${ci + 1}/${countries.length}] ${cc}: ${s.n} pages  Worker hit ${s.hitKK}/miss ${s.missKK}  CF hit ${s.hitCF}  avg ${s.n ? Math.round(s.ms / s.n) : 0}ms  (${secs}s)\n`);
  }
  console.log(`\nPHASE 2 TOTAL: ${grand.req} requests, Worker HIT ${grand.hitKK} / MISS ${grand.missKK}, CF HIT ${grand.hitCF}, errors ${grand.errors}`);
}

// ---- run -------------------------------------------------------------------
(async () => {
  console.log(`Warming ${ORIGIN}  (concurrency=${CONCURRENCY}, max=${MAX_PAGES}${USE_SITEMAP ? ', +sitemap' : ''}${COUNTRIES_ARG ? ', +countries' : ''})\n`);
  if (USE_SITEMAP) await seedSitemap();
  enqueue(normalize(BASE, BASE));

  const start = Date.now();
  const s1 = await crawl();
  const urls = [...visited].filter(shouldCrawl);

  console.log('\n──────── PHASE 1 (discover + default) ────────');
  console.log(`pages: ${s1.fetched}  Worker HIT ${s1.hitKK}/MISS ${s1.missKK}  CF HIT ${s1.hitCF}  errors ${s1.errors}  avg ${s1.fetched ? Math.round(s1.ms / s1.fetched) : 0}ms`);
  console.log('(note: x-litespeed-cache is unreliable behind the Worker — KK/CF = the cache the visitor actually gets)');

  if (COUNTRIES_ARG) {
    let countries;
    if (COUNTRIES_ARG === 'popular') {
      countries = POPULAR;
    } else if (COUNTRIES_ARG === true || COUNTRIES_ARG === 'all') {
      countries = discoveredCountries && discoveredCountries.length ? discoveredCountries : ALL_FALLBACK;
      console.log(`Countries: ${countries.length} (${discoveredCountries ? 'from switcher' : 'from fallback list'})`);
    } else {
      countries = String(COUNTRIES_ARG).toUpperCase().split(',').map((c) => c.trim()).filter((c) => /^[A-Z]{2}$/.test(c));
    }
    await warmCountries(countries, urls);
  }

  if (VERIFY) {
    console.log('\n──────── VERIFY (re-fetch default set) ────────');
    const s = { hitKK: 0, missKK: 0, ms: 0, n: 0 };
    await pool(urls, async (url) => {
      try { const r = await fetchOnce(url); s.n++; s.ms += r.ms; if (/hit/i.test(r.kk)) s.hitKK++; else if (/miss/i.test(r.kk)) s.missKK++; } catch {}
    });
    console.log(`verify: ${s.n} pages, Worker HIT ${s.hitKK}/MISS ${s.missKK}, avg ${s.n ? Math.round(s.ms / s.n) : 0}ms`);
  }

  console.log(`\nTotal URLs discovered: ${urls.length}   Total time: ${((Date.now() - start) / 1000).toFixed(1)}s`);
})();
