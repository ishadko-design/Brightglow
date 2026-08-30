// Programmatic local-SEO page generator for Brightglow.
//
//   node site/local/_build.mjs
//
// Reads _data.mjs (trades × cities × real price bands) and writes one static
// HTML page per trade×city into site/local/, plus site/sitemap.xml.
// Pages are self-contained (inline CSS, shared fonts) so they load fast and
// rank on their own. Each page is genuinely differentiated: local price
// scaling, local licensing note, unique title/description/FAQ.

import { CITIES, TRADES } from "./_data.mjs";
import { writeFileSync, readdirSync, unlinkSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const SITE = join(HERE, "..");
const ORIGIN = "https://brightglow.co";
const APP_URL = "https://apps.apple.com/us/app/brightglow-find-local-pros/id6796186438";

const money = (n) =>
  n >= 1000 ? "$" + (Math.round(n / 100) * 100).toLocaleString("en-US") : "$" + Math.round(n);
const perSqft = (n) => (Number.isInteger(n) ? "$" + n : "$" + n.toFixed(2));

// Scale a national band by the city's labour index. Wide bands (which already
// span huge ranges) are left unscaled so we don't overstate precision.
function localBand(job, index) {
  if (job.wide) return [job.low, job.high];
  return [job.low * index, job.high * index];
}

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const fill = (s, map) => s.replace(/\{(\w+)\}/g, (_, k) => (k in map ? map[k] : `{${k}}`));

function pageHtml(trade, city) {
  const bands = trade.jobs.map((j) => {
    const [lo, hi] = localBand(j, city.index);
    return { label: j.label, lo, hi, wide: j.wide };
  });
  const allLo = Math.min(...bands.map((b) => b.lo));
  const allHi = Math.max(...bands.map((b) => b.hi));

  const vars = {
    CITY: city.name,
    MIN: money(allLo),
    MAX: money(allHi),
    SQFTMIN: trade.perSqft ? perSqft(trade.perSqft.low * city.index) : "",
    SQFTMAX: trade.perSqft ? perSqft(trade.perSqft.high * city.index) : "",
  };

  const title = `${trade.name} Costs in ${city.name}, CA (2026) | Brightglow`;
  const desc = fill(
    `How much does a ${trade.verb} cost in ${city.name}? Typical {CITY} prices for common ${trade.name.toLowerCase()} jobs, plus real pro photos and an instant estimate.`,
    vars
  ).slice(0, 158);
  // Canonical must point at the URL that actually serves 200. Cloudflare Pages
  // serves these as clean (extensionless) URLs and 307-redirects the .html form,
  // so a .html canonical points at a redirect and Google discards it
  // ("Duplicate without user-selected canonical"). Always use the clean URL.
  const canonical = `${ORIGIN}/local/${trade.slug}-${city.slug}`;
  const intro = fill(trade.intro, vars);

  const rows = bands
    .map(
      (b) => `        <tr>
          <td>${esc(b.label)}</td>
          <td class="range">${money(b.lo)}&nbsp;–&nbsp;${money(b.hi)}${
        b.wide ? '<span class="wide" title="Prices vary widely for this job">*</span>' : ""
      }</td>
        </tr>`
    )
    .join("\n");

  const perSqftLine = trade.perSqft
    ? `<p class="persqft">Rule of thumb: about <strong>${vars.SQFTMIN}–${vars.SQFTMAX}</strong> per ${trade.perSqft.unit} in ${city.name}.</p>`
    : "";

  const drivers = trade.drivers.map((d) => `        <li>${esc(fill(d, vars))}</li>`).join("\n");

  const faqItems = trade.faqs.map(([q, a]) => [fill(q, vars), fill(a, vars)]);
  const faqHtml = faqItems
    .map(
      ([q, a]) => `      <details class="faq">
        <summary>${esc(q)}</summary>
        <p>${esc(a)}</p>
      </details>`
    )
    .join("\n");

  // Structured data: FAQPage + Service, so Google can show rich results.
  const jsonld = {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "Service",
        serviceType: `${trade.name} services`,
        areaServed: { "@type": "City", name: `${city.name}, CA` },
        provider: { "@type": "Organization", name: "Brightglow", url: ORIGIN },
        offers: { "@type": "AggregateOffer", priceCurrency: "USD", lowPrice: Math.round(allLo), highPrice: Math.round(allHi) },
      },
      {
        "@type": "FAQPage",
        mainEntity: faqItems.map(([q, a]) => ({
          "@type": "Question",
          name: q,
          acceptedAnswer: { "@type": "Answer", text: a },
        })),
      },
    ],
  };

  const otherCities = CITIES.filter((c) => c.slug !== city.slug)
    .map((c) => `<a href="${trade.slug}-${c.slug}">${esc(trade.name)} in ${esc(c.name)}</a>`)
    .join("\n        ");
  const otherTrades = TRADES.filter((t) => t.slug !== trade.slug)
    .map((t) => `<a href="${t.slug}-${city.slug}">${esc(t.name)} in ${esc(city.name)}</a>`)
    .join("\n        ");

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${esc(title)}</title>
  <meta name="description" content="${esc(desc)}">
  <link rel="canonical" href="${canonical}">
  <meta name="theme-color" content="#000000">
  <meta property="og:title" content="${esc(title)}">
  <meta property="og:description" content="${esc(desc)}">
  <meta property="og:type" content="website">
  <meta property="og:url" content="${canonical}">
  <link rel="icon" type="image/png" href="../favicon.png">
  <link rel="apple-touch-icon" href="../apple-touch-icon.png">
  <link rel="stylesheet" href="../styles.css?v=27">
  <script type="application/ld+json">${JSON.stringify(jsonld)}</script>
  <!-- Page-specific content styles. Everything visual (black + amber gradient,
       header, wordmark, blue CTA, footer, fonts, tokens) comes from styles.css
       via body.landing; this only lays out the article content in-brand. -->
  <style>
    .doc{position:relative;z-index:1;width:calc(660 * var(--s));max-width:100%;margin:0 auto;padding:0 calc(24 * var(--s))}
    @media (min-width:700px){.doc{width:660px;padding:0 24px}}
    .doc-hero{text-align:center;padding-top:calc(40 * var(--s))}
    .doc h1{font-family:"Lato",system-ui,sans-serif;font-weight:400;font-size:calc(40 * var(--s));line-height:1.15;color:var(--white)}
    @media (min-width:700px){.doc h1{font-size:44px}}
    .doc-kicker{margin-top:12px;font-size:14px;color:rgba(255,255,255,.5)}
    .doc-intro{margin:20px auto 0;max-width:56ch;font-family:"Poppins",system-ui,sans-serif;font-weight:300;font-size:16px;line-height:1.65;color:rgba(255,255,255,.82)}
    .doc .appstore-btn{margin-top:calc(28 * var(--s))}
    .doc h2{font-family:"Lato",system-ui,sans-serif;font-weight:700;font-size:22px;margin:48px 0 4px;color:var(--white)}
    .price{width:100%;border-collapse:collapse;margin-top:12px;font-family:"Poppins",system-ui,sans-serif;font-weight:300}
    .price td{padding:15px 0;border-bottom:1px solid rgba(255,255,255,.1);font-size:16px;color:rgba(255,255,255,.9)}
    .price td.range{text-align:right;white-space:nowrap;color:var(--white)}
    .wide{color:rgba(255,255,255,.45)}
    .persqft{margin-top:14px;color:rgba(255,255,255,.82);font-size:15px}
    .note{margin-top:16px;font-size:13px;line-height:1.6;color:rgba(255,255,255,.45)}
    .doc ul{margin:14px 0 0;padding-left:20px}
    .doc li{margin:10px 0;color:rgba(255,255,255,.85);font-size:16px;line-height:1.55}
    .card{background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.1);border-radius:24px;padding:28px;margin:44px 0;text-align:center}
    .card h3{font-family:"Lato",system-ui,sans-serif;font-weight:700;font-size:20px;color:var(--white)}
    .card p{margin:10px auto 0;max-width:42ch;color:rgba(255,255,255,.82);font-size:15px;line-height:1.6}
    .faq{border-bottom:1px solid rgba(255,255,255,.1);padding:18px 0}
    .faq summary{cursor:pointer;list-style:none;font-family:"Lato",system-ui,sans-serif;font-weight:700;font-size:17px;color:var(--white);display:flex;justify-content:space-between;gap:16px}
    .faq summary::-webkit-details-marker{display:none}
    .faq summary::after{content:"+";color:rgba(255,255,255,.5);font-weight:400}
    .faq[open] summary::after{content:"\\2013"}
    .faq p{margin-top:12px;color:rgba(255,255,255,.82);font-size:15px;line-height:1.6}
    .xlinks h3{font-family:"Lato",system-ui,sans-serif;font-weight:700;font-size:15px;color:rgba(255,255,255,.5);margin-bottom:10px}
    .xlinks .row{display:flex;flex-wrap:wrap;gap:10px 20px;margin-bottom:24px}
    .xlinks a{color:rgba(255,255,255,.6);text-decoration:none;font-size:14px}
    .xlinks a:hover{color:var(--white)}
  </style>
</head>
<body class="landing">
  <header class="topbar">
    <a class="logo" href="../">
      <img class="appicon" src="../media/appicon.png" alt="">
      <span class="wordmark">Brightglow</span>
    </a>
    <a class="biz-link" href="../biz/">For businesses</a>
  </header>

  <main class="doc">
    <div class="doc-hero">
      <h1>${esc(trade.name)} Costs<br>in ${esc(city.name)}, CA</h1>
      <p class="doc-kicker">Typical 2026 prices · ${esc(city.name)} area</p>
      <p class="doc-intro">${esc(intro)}</p>
      <a class="appstore-btn" href="${APP_URL}">Get your instant estimate</a>
    </div>

    <h2>What ${esc(trade.name.toLowerCase())} costs in ${esc(city.name)}</h2>
    <table class="price">
      <tbody>
${rows}
      </tbody>
    </table>
    ${perSqftLine}
    <p class="note">Ranges are typical all-in prices${
      trade.jobs.some((j) => j.wide) ? " (* = varies widely by job)" : ""
    }, scaled from national 2026 figures (Homewyse, This Old House, Forbes Home, Thumbtack) to ${esc(
    city.name
  )}-area labour. Your exact price depends on your specific job — get it free in the app.</p>

    <h2>What drives the price</h2>
    <ul>
${drivers}
    </ul>

    <div class="card">
      <h3>See the work before you hire</h3>
      <p>Brightglow shows real photos of ${esc(city.name)} ${esc(
    trade.verb
  )}s' finished jobs, a price range for yours, and a spam-free chat with the ones that fit.</p>
      <a class="appstore-btn" style="margin:18px auto 0" href="${APP_URL}">Download free</a>
    </div>

    <h2>${esc(trade.name)} in ${esc(city.name)} — FAQ</h2>
${faqHtml}

    <div class="xlinks" style="margin-top:44px">
      <h3>${esc(trade.name)} in other Bay Area cities</h3>
      <div class="row">
        ${otherCities}
      </div>
      <h3>Other trades in ${esc(city.name)}</h3>
      <div class="row">
        ${otherTrades}
      </div>
    </div>
  </main>

  <footer class="landing-footer">
    <a class="footer-terms" href="../terms">Terms of Service</a>
    <a href="mailto:hello@brightglow.co">hello@brightglow.co</a>
    <div class="copyright">© 2026 Brightglow LLC · estimates are informational, not quotes</div>
  </footer>
</body>
</html>
`;
}

// ---- generate ----
const LOCAL_DIR = HERE;
// clear old generated pages (anything not starting with "_")
for (const f of readdirSync(LOCAL_DIR)) {
  if (f.endsWith(".html")) unlinkSync(join(LOCAL_DIR, f));
}

const urls = [];
let count = 0;
for (const trade of TRADES) {
  for (const city of CITIES) {
    const slug = `${trade.slug}-${city.slug}`;
    writeFileSync(join(LOCAL_DIR, `${slug}.html`), pageHtml(trade, city));
    // Sitemap lists the clean (200-serving) URL, not the .html redirect.
    urls.push(`${ORIGIN}/local/${slug}`);
    count++;
  }
}

// ---- sitemap (includes the home + business pages too) ----
const staticUrls = [`${ORIGIN}/`, `${ORIGIN}/biz`];
const today = "2026-08-19";
const sitemap = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${[...staticUrls, ...urls]
  .map(
    (u) => `  <url><loc>${u}</loc><lastmod>${today}</lastmod><changefreq>monthly</changefreq></url>`
  )
  .join("\n")}
</urlset>
`;
writeFileSync(join(SITE, "sitemap.xml"), sitemap);

// ---- robots.txt (point crawlers at the sitemap) ----
writeFileSync(
  join(SITE, "robots.txt"),
  `User-agent: *\nAllow: /\n\nSitemap: ${ORIGIN}/sitemap.xml\n`
);

console.log(`Generated ${count} local pages + sitemap.xml (${urls.length + staticUrls.length} urls) + robots.txt`);
