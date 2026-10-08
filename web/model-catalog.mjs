import catalog from '../Sources/Fritz/ModelCatalog.json' with { type: 'json' };

const body = `${JSON.stringify(catalog, null, 2)}\n`;
let validator;

/** Mount at rel.me/supported-models.json. The representation and ETag share one source. */
export async function serveModelCatalog(request) {
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return new Response('Method Not Allowed', { status: 405, headers: { Allow: 'GET, HEAD' } });
  }
  validator ??= crypto.subtle.digest('SHA-256', new TextEncoder().encode(body))
    .then((digest) => `"${Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('')}"`);
  const etag = await validator;
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'public, max-age=300, s-maxage=300',
    'Content-Type': 'application/json; charset=utf-8',
    'X-Content-Type-Options': 'nosniff',
    ETag: etag,
  };
  const validators = request.headers.get('If-None-Match')?.split(',').map((value) => value.trim().replace(/^W\//, ''));
  if (validators?.some((value) => value === '*' || value === etag)) return new Response(null, { status: 304, headers });
  return new Response(request.method === 'HEAD' ? null : body, { headers });
}
