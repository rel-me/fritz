import catalog from '../Sources/Fritz/ModelCatalog.json' with { type: 'json' };

const body = `${JSON.stringify(catalog, null, 2)}\n`;
const validatorsByBody = new Map();

/** Mount at rel.me/supported-models.json. The representation and ETag share one source. */
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

/** Minimal browser view of the same canonical catalog, mounted at rel.me/catalog. */
export async function serveModelCatalogPage(request) {
  page ??= renderPage();
  return serve(request, page, 'text/html; charset=utf-8');
}

function renderPage() {
  const sections = Object.entries(catalog.model_info.providers).map(([provider, { models }]) => {
    const rows = Object.entries(models).sort(([a], [b]) => a.localeCompare(b)).map(([id, model]) => {
      const capabilities = [model.reasoning && 'Reasoning', model.tool_call && 'Tools', model.attachment && 'Attachments', ...(model.modalities?.input ?? []).map((value) => `${value} input`), ...(model.modalities?.output ?? []).map((value) => `${value} output`)].filter(Boolean).join(', ');
      const reviewed = provider === 'openai' ? catalog.reviewed_openai.models[id] : undefined;
      const metadata = reviewed ? { ...model, reviewed_request_capabilities: reviewed } : model;
      return `<tr><td><details><summary>${escape(model.name || id)}<small>${escape(id)}</small></summary><pre>${escape(JSON.stringify(metadata, null, 2))}</pre></details></td><td>${escape(price(model.cost?.input))}</td><td>${escape(price(model.cost?.output))}</td><td>${escape(price(model.cost?.cache_read))}</td><td>${escape(number(model.limit?.context))}</td><td>${escape(capabilities || 'Unavailable')}</td></tr>`;
    }).join('');
    return `<section><h2>${escape(provider)} <small>${Object.keys(models).length} models</small></h2><div class="table"><table><thead><tr><th scope="col">Model and metadata</th><th scope="col">Input</th><th scope="col">Output</th><th scope="col">Cache read</th><th scope="col">Context tokens</th><th scope="col">Capabilities</th></tr></thead><tbody>${rows}</tbody></table></div></section>`;
  }).join('');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>REL model catalog</title><style>
:root{color-scheme:light dark;font:15px system-ui,sans-serif}body{max-width:1200px;margin:40px auto;padding:0 20px;line-height:1.5}h1{font-size:26px}h2{margin-top:32px;font-size:20px}small{font-size:12px;font-weight:normal;opacity:.7}summary small{display:block}a{color:inherit}input{font:inherit;padding:8px;width:min(100%,360px);box-sizing:border-box}.table{overflow:auto}table{border-collapse:collapse;width:100%;text-align:left;font-size:13px}th,td{border-bottom:1px solid #8885;padding:10px;vertical-align:top}th{white-space:nowrap}summary{cursor:pointer;min-width:160px}pre{max-width:500px;max-height:400px;overflow:auto;font-size:12px}td:nth-child(n+2):nth-child(-n+5){white-space:nowrap}
</style></head><body><h1>REL model catalog</h1><p>Metadata and prices imported from <a href="https://models.dev">Models.dev</a>. Imported ${escape(catalog.model_info.imported_at)}. Catalog ${escape(catalog.catalog_version)}.</p><p>Prices are USD per million tokens. Expand a model to view all metadata, cache write rates, and pricing tiers. Provider APIs determine which models your account can access.</p><p><a href="/supported-models.json">View JSON</a></p><label for="search">Filter models</label><br><input id="search" type="search" placeholder="Model name, ID, or capability">${sections}<script>
const search=document.getElementById('search');search.addEventListener('input',()=>{const query=search.value.toLowerCase();for(const section of document.querySelectorAll('section')){let count=0;for(const row of section.querySelectorAll('tbody tr')){row.hidden=!row.textContent.toLowerCase().includes(query);if(!row.hidden)count++;}section.hidden=count===0;}});
</script></body></html>`;
}
