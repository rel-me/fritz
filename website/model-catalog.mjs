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
const creatorNames = {
  ...providerNames,
  gemini: 'Google', google: 'Google', qwen: 'Qwen', meta: 'Meta', 'meta-llama': 'Meta',
  mistralai: 'Mistral AI', deepseek: 'DeepSeek', 'x-ai': 'xAI', 'z-ai': 'Z.ai',
  moonshotai: 'Moonshot AI', nvidia: 'NVIDIA', nousresearch: 'Nous Research',
};
const gigabytes = (bytes) => `${(bytes / 1e9).toLocaleString('en-US', { maximumFractionDigits: 2 })} GB`;

function modelDetails(id, name, metadata) {
  return `<details><summary>${escape(name || id)}<small>${escape(id)}</small></summary><pre>${escape(JSON.stringify(metadata, null, 2))}</pre></details>`;
}

function cell(value, format = escape) {
  return `<td data-value="${escape(value)}">${value == null ? '—' : format(value)}</td>`;
}

function modelCell(id, name, metadata) {
  return `<td data-value="${escape(name || id)}">${modelDetails(id, name, metadata)}</td>`;
}

function modelRow({ id, creator, type, abliterated, metal, capabilities = [], cells }) {
  return {
    creator, capabilities,
    html: `<tr data-type="${type}" data-model-id="${escape(id)}"${abliterated ? ' data-abliterated' : ''}${metal ? ' data-metal' : ''}${capabilities.length ? ` data-capabilities="${escape(capabilities.join(', '))}"` : ''}>${cells}</tr>`,
  };
}

function table(title, headings, models) {
  const columns = headings.map(([heading, mode]) =>
    `<th scope="col" data-sort-type="${mode}"><button type="button" disabled>${escape(heading)}</button></th>`).join('');
  const groups = new Map();
  for (const { creator, html } of models) {
    if (!groups.has(creator)) groups.set(creator, []);
    groups.get(creator).push(html);
  }
  const bodies = [...groups].map(([creator, rows]) => `<tbody data-creator="${escape(creator)}">
    <tr class="creator-row"><th scope="rowgroup" colspan="${headings.length}">
      <span data-creator-label>${escape(creator)}</span>
      <button type="button" data-creator-toggle aria-expanded="true" hidden>${escape(creator)} <span data-creator-count></span></button>
    </th></tr>${rows.join('')}
  </tbody>`).join('');
  return `<div class="catalog-table" tabindex="0" role="region" aria-label="${escape(title)}">
    <table><thead><tr>${columns}</tr></thead>${bodies}</table></div>`;
}

function localRow(model) {
  const type = model.category === 'decision' ? 'Decision' : 'LLM';
  const score = model.benchmark_score;
  return modelRow({
    id: model.id, creator: model.family, type,
    abliterated: model.abliterated === true, metal: type === 'LLM' || model.engine === 'bosun',
    cells: [
      modelCell(model.id, model.name, model), cell(type), cell(model.size, gigabytes),
      cell(model.memory_gb, (memory) => `${number(memory)} GB`),
      cell(score?.points, (points) => `<a href="${escape(score.source_url)}" title="${escape(score.configuration)}">${points}</a>`),
      cell(model.limit?.context ?? model.limit?.input, number),
      cell(model.limit?.runtime, number),
    ].join(''),
  });
}

function remoteCreator(provider, id) {
  const namespace = provider === 'openrouter' && id.includes('/') ? id.split('/')[0].replace(/^~/, '') : provider;
  if (Object.hasOwn(creatorNames, namespace)) return creatorNames[namespace];
  return namespace.replace(/(^|-)([a-z])/g, (_, boundary, letter) =>
    `${boundary ? ' ' : ''}${letter.toUpperCase()}`);
}

function remoteRow(provider, id, model, { creator = remoteCreator(provider, id), type = 'LLM' } = {}) {
  const capabilities = [
    model.reasoning && 'Reasoning', model.tool_call && 'Tools', model.attachment && 'Attachments',
    ...(model.modalities?.input ?? []).map((value) => `${value} input`),
    ...(model.modalities?.output ?? []).map((value) => `${value} output`),
  ].filter(Boolean);
  const reviewed = provider === 'openai' ? catalog.reviewed_openai.models[id] : undefined;
  const metadata = reviewed ? { ...model, reviewed_request_capabilities: reviewed } : model;
  return modelRow({
    id, creator, type, capabilities,
    cells: [
      modelCell(id, model.name, metadata), cell(providerNames[provider] ?? provider), cell(type),
      cell(model.cost?.input, price), cell(model.cost?.output, price), cell(model.cost?.cache_read, price),
      cell((model.limit?.context || model.limit?.input) || null, number), cell(capabilities.join(', ') || null),
    ].join(''),
  });
}

function select(label, name, entries) {
  return `<label>${escape(label)} <select name="${name}">${entries.map(([value, text]) =>
    `<option value="${escape(value)}">${escape(text)}</option>`).join('')}</select></label>`;
}

function filters({ local = false, models }) {
  const creators = [...new Set(models.map(({ creator }) => creator))].sort((a, b) => a.localeCompare(b));
  const creatorFilter = select('Creator', 'creator', [['', 'All creators'], ...creators.map((name) => [name, name])]);
  const scores = [...new Set(catalog.local_chat.models.concat(catalog.local_decision.models)
    .map((model) => model.benchmark_score?.points).filter(Number.isFinite))].sort((a, b) => a - b);
  const localFilters = [
    select('Score', 'score', [['', 'All scores'], ['scored', 'Scored only'], ['unscored', 'Unscored only'],
      ...scores.slice(1).map((points) => [points, `At least ${points}`])]),
    '<label>RAM available (GB) <input name="memory" type="number" min="1" step="1" inputmode="numeric"></label>',
    select('Hardware', 'hardware', [['', 'Any hardware'], ['cpu', 'CPU only']]),
    '<label class="check"><input name="abliterated" type="checkbox"> Abliterated</label>',
  ];
  const remoteFilters = [
    select('Provider', 'provider', [['', 'All providers'], ...Object.values(providerNames).concat(
      Object.values(catalog.remote_decision).map((model) => model.provider_name)).map((name) => [name, name])]),
    select('Capability', 'capability', [['', 'All capabilities'],
      ...[...new Set(models.flatMap((model) => model.capabilities))].sort((a, b) => a.localeCompare(b))
        .map((value) => [value, value[0].toUpperCase() + value.slice(1)])]),
  ];
  return `<form class="catalog-filters" hidden>
    <label class="catalog-search">Search models <input name="query" type="search" placeholder="Name, ID, creator, or capability"></label>
    ${creatorFilter}
    ${select('Model type', 'type', [['', 'All model types'], ['LLM', 'LLMs'], ['Decision', 'Decision models']])}
    ${(local ? localFilters : remoteFilters).join('')}
    <button type="reset">Clear filters</button>
  </form>
  <p class="catalog-status" role="status" hidden></p>`;
}

function renderPage() {
  const local = catalog.local_chat.models.concat(catalog.local_decision.models).map(localRow);
  const remote = Object.entries(catalog.model_info.providers).flatMap(([provider, { models }]) =>
    Object.entries(models).map(([id, model]) => remoteRow(provider, id, model)));
  for (const [id, reviewed] of Object.entries(catalog.reviewed_openai.models)) {
    if (reviewed.limit && !catalog.model_info.providers.openai.models[id]) {
      remote.push(remoteRow('openai', id, { name: reviewed.displayName, limit: reviewed.limit }));
    }
  }
  remote.sort((a, b) => a.creator.localeCompare(b.creator));
  remote.push(...Object.entries(catalog.remote_decision).map(([provider, model]) =>
    remoteRow(model.provider_name, model.id, model, {
      creator: provider === 'openai-decisions' ? 'OpenAI' : model.provider_name, type: 'Decision',
    })));
  const localColumns = [['Model', 'text'], ['Type', 'text'], ['Download', 'number'], ['Recommended RAM', 'number'], ['Score', 'number'], ['Model context (tokens)', 'number'], ['Fritz window (tokens)', 'number']];
  const remoteColumns = [['Model', 'text'], ['Provider', 'text'], ['Type', 'text'], ['Input', 'number'],
    ['Output', 'number'], ['Cache read', 'number'], ['Context tokens', 'number'], ['Capabilities', 'text']];
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Fritz model catalog</title><link rel="icon" href="/favicon.svg"><link rel="stylesheet" href="/styles.css">
<link rel="stylesheet" href="/catalog.css?v=2"><script src="/catalog.mjs?v=2" type="module"></script></head>
<body><header class="nav"><div class="nav-inner">
  <a class="wordmark" href="/" aria-label="Fritz home"><span class="raven raven--mark" aria-hidden="true"></span><span>fritz</span></a>
  <a href="/supported-models.json">View JSON</a>
</div></header>
<main class="catalog">
  <h1>Model catalog</h1><p class="catalog-version">Version ${escape(catalog.catalog_version)}</p>
  <nav class="catalog-nav" aria-label="Model locations">
    <a href="#local">Local models</a><a href="#remote">Remote models</a>
  </nav>
  <section id="local" data-catalog-location>
    <h2>Local models</h2>
    ${filters({ local: true, models: local })}
    ${table('Local models by creator', localColumns, local)}
    <p class="catalog-note"><a href="https://artificialanalysis.ai/methodology/intelligence-benchmarking">Score methodology</a></p>
  </section>
  <section id="remote" data-catalog-location>
    <h2>Remote models</h2>
    <p class="catalog-note">Pricing from <a href="https://models.dev">Models.dev</a> is shown in USD per million tokens. Context limits are published snapshots. Providers can apply different limits to your account or route.</p>
    ${filters({ models: remote })}
    ${table('Remote models by creator', remoteColumns, remote)}
  </section>
</main></body></html>`;
}
