import catalog from '../Sources/Fritz/ModelCatalog.json' with { type: 'json' };

const body = `${JSON.stringify(catalog, null, 2)}\n`;
const validatorsByBody = new Map();

export async function serveModelCatalog(request) {
  return serve(request, body, 'application/json; charset=utf-8');
}

async function serve(request, representation, contentType) {
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return new Response('Method Not Allowed', { status: 405, headers: { Allow: 'GET, HEAD' } });
  }
  if (!validatorsByBody.has(representation)) validatorsByBody.set(representation, crypto.subtle.digest('SHA-256', new TextEncoder().encode(representation))
    .then((digest) => `"${Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('')}"`));
  const etag = await validatorsByBody.get(representation);
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'public, max-age=300, s-maxage=300',
    'Content-Type': contentType,
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'strict-origin-when-cross-origin',
    'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    ETag: etag,
  };
  const validators = request.headers.get('If-None-Match')?.split(',').map((value) => value.trim().replace(/^W\//, ''));
  if (validators?.some((value) => value === '*' || value === etag)) return new Response(null, { status: 304, headers });
  return new Response(request.method === 'HEAD' ? null : representation, { headers });
}

const escape = (value) => String(value ?? '').replace(/[&<>"']/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]);
const price = (value) => typeof value === 'number' ? `$${value.toLocaleString('en-US', { maximumFractionDigits: 6 })}` : 'Unavailable';
const number = (value) => typeof value === 'number' ? value.toLocaleString('en-US') : 'Unavailable';
let page;

export async function serveModelCatalogPage(request) {
  page ??= renderPage();
  return serve(request, page, 'text/html; charset=utf-8');
}

const providerNames = { openai: 'OpenAI', anthropic: 'Anthropic', gemini: 'Google Gemini', openrouter: 'OpenRouter' };
const gigabytes = (bytes) => `${(bytes / 1e9).toLocaleString('en-US', { maximumFractionDigits: 2 })} GB`;

function modelDetails(id, name, metadata) {
  return `<details><summary>${escape(name || id)}<small>${escape(id)}</small></summary><pre>${escape(JSON.stringify(metadata, null, 2))}</pre></details>`;
}

function table(title, headings, rows) {
  const columns = headings.map((heading) => `<th scope="col">${escape(heading)}</th>`).join('');
  return `<section data-catalog-group><h3>${escape(title)}</h3><div class="catalog-table" tabindex="0" role="region" aria-label="${escape(title)}">
    <table><thead><tr>${columns}</tr></thead><tbody>${rows.join('')}</tbody></table></div></section>`;
}

function localTable(title, models) {
  return table(title, ['Model', 'Family', 'Download', 'Recommended memory'], models.map((model) =>
    `<tr><td>${modelDetails(model.id, model.name, model)}</td><td>${escape(model.family)}</td><td>${gigabytes(model.size)}</td><td>${escape(model.memory_gb)} GB</td></tr>`));
}

function remoteTable(provider, models) {
  const rows = Object.entries(models).sort(([a], [b]) => a.localeCompare(b)).map(([id, model]) => {
    const capabilities = [
      model.reasoning && 'Reasoning', model.tool_call && 'Tools', model.attachment && 'Attachments',
      ...(model.modalities?.input ?? []).map((value) => `${value} input`),
      ...(model.modalities?.output ?? []).map((value) => `${value} output`),
    ].filter(Boolean).join(', ');
    const reviewed = provider === 'openai' ? catalog.reviewed_openai.models[id] : undefined;
    const metadata = reviewed ? { ...model, reviewed_request_capabilities: reviewed } : model;
    return `<tr><td>${modelDetails(id, model.name, metadata)}</td><td>${price(model.cost?.input)}</td>
      <td>${price(model.cost?.output)}</td><td>${price(model.cost?.cache_read)}</td>
      <td>${number(model.limit?.context)}</td><td>${escape(capabilities || 'Unavailable')}</td></tr>`;
  });
  return table(providerNames[provider] ?? provider, ['Model', 'Input', 'Output', 'Cache read', 'Context tokens', 'Capabilities'], rows);
}

function renderPage() {
  const remote = Object.entries(catalog.model_info.providers).map(([provider, { models }]) => remoteTable(provider, models)).join('');
  const decisions = table('Decision models', ['Model', 'Provider'], Object.values(catalog.remote_decision).map((model) =>
    `<tr><td>${modelDetails(model.id, model.name, model)}</td><td>${escape(model.provider_name)}</td></tr>`));
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Fritz model catalog</title><link rel="icon" href="/favicon.svg"><link rel="stylesheet" href="/styles.css">
<link rel="stylesheet" href="/catalog.css"><script src="/catalog.mjs" type="module"></script></head>
<body><header class="nav"><div class="nav-inner">
  <a class="wordmark" href="/" aria-label="Fritz home"><span class="raven raven--mark" aria-hidden="true"></span><span>fritz</span></a>
  <a href="/supported-models.json">View JSON</a>
</div></header>
<main class="catalog">
  <h1>Model catalog</h1><p class="catalog-version">Version ${escape(catalog.catalog_version)}</p>
  <label for="search" hidden>Filter models</label>
  <input id="search" type="search" placeholder="Model name, ID, or capability" hidden>
  <p id="catalog-empty" role="status" hidden>No models match your search.</p>
  <section data-catalog-location>
    <h2>Local models</h2>
    ${localTable('Chat models', catalog.local_chat.models)}
    ${localTable('Decision models', catalog.local_decision.models)}
  </section>
  <section data-catalog-location>
    <h2>Remote models</h2>
    <p>Provider APIs determine which models your account can access. Pricing from <a href="https://models.dev">Models.dev</a> is shown in USD per million tokens.</p>
    ${remote}
    ${decisions}
  </section>
</main></body></html>`;
}
