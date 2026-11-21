import assert from 'node:assert/strict';
import test from 'node:test';
import worker from './worker.mjs';

const request = (path, init) => worker.fetch(new Request(`https://fritz.rel.me${path}`, init));

test('catalog HTTP representation supports revalidation and HEAD', async () => {
  const fetch = (method, headers = {}) => request('/supported-models.json', { method, headers });
  const response = await fetch('GET');
  assert.equal(response.status, 200);
  const catalog = await response.json();
  assert.ok(Number.isSafeInteger(catalog.catalog_version) && catalog.catalog_version > 0);
  assert.ok(catalog.local_chat.models.some((model) => model.id === 'qwen3-0.6b-q4_k_m'));
  assert.ok(catalog.local_decision.models.some((model) => model.id === 'laya-en'));
  assert.equal(catalog.remote_decision.jev.id, 'jev-latest');
  assert.equal(catalog.model_info.currency, 'USD');
  assert.equal(catalog.model_info.unit, 'per_million_tokens');
  assert.equal(catalog.model_info.providers.openai.models['gpt-6-luna'].cost.input, 0.1);
  assert.ok(catalog.reviewed_openai.models['gpt-6-luna'].reasoningEfforts.includes('medium'));
  const etag = response.headers.get('etag');
  assert.match(etag, /^"[0-9a-f]{64}"$/);
  for (const value of [etag, `W/${etag}`, `"old", ${etag}`, '*']) {
    const unchanged = await fetch('GET', { 'If-None-Match': value });
    assert.equal(unchanged.status, 304);
    assert.equal(await unchanged.text(), '');
    assert.equal(unchanged.headers.get('etag'), etag);
  }
  assert.equal((await fetch('GET', { 'If-None-Match': '"old"' })).status, 200);
  const head = await fetch('HEAD');
  assert.equal(head.headers.get('etag'), etag);
  assert.equal(await head.text(), '');
  assert.equal((await fetch('POST')).status, 405);
});

test('browser catalog exposes prices, capabilities, metadata and conditional HTML', async () => {
  const response = await request('/catalog');
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /^text\/html/);
  const html = await response.text();
  assert.match(html, /<title>Fritz model catalog<\/title>/);
  assert.match(html, /<h2>Local models<\/h2>/);
  assert.match(html, /<h2>Remote models<\/h2>/);
  assert.match(html, /qwen3-0.6b-q4_k_m/);
  assert.match(html, /laya-en/);
  assert.match(html, /gpt-6-luna/);
  assert.match(html, /jev-latest/);
  assert.match(html, /USD per million tokens/);
  assert.match(html, /reviewed_request_capabilities/);
  assert.match(html, /Filter models/);
  assert.match(html, /&quot;cache_read&quot;/);
  const etag = response.headers.get('etag');
  const unchanged = await request('/catalog', { headers: { 'If-None-Match': etag } });
  assert.equal(unchanged.status, 304);
  assert.equal(await unchanged.text(), '');
  const head = await request('/catalog', { method: 'HEAD' });
  assert.equal(head.headers.get('etag'), etag);
  assert.equal(await head.text(), '');
});
