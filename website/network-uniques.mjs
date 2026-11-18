// Server-only pseudonyms: no installation ID, cookie ID, or raw IP is persisted.
export async function networkToken(request, env, appID, now = new Date()) {
  const ip = request.headers.get("cf-connecting-ip");
  if (!env.ANALYTICS_UNIQUES_KEY || !ip) return null;
  const day = now.toISOString().slice(0, 10);
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.ANALYTICS_UNIQUES_KEY),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const bytes = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(JSON.stringify([appID, day, ip])));
  return { day, token: Array.from(new Uint8Array(bytes), b => b.toString(16).padStart(2, "0")).join("") };
}
export async function storeNetworkToken(env, appID, network) {
  if (!network) return;
  // Keep today's and yesterday's hashes only. Aggregate daily counts survive expiry.
  const result = await env.DB.prepare(`INSERT OR IGNORE INTO daily_network_keys (app_id, day, network_hash) VALUES (?, ?, ?)`)
    .bind(appID, network.day, network.token).run();
  if (!result.success) throw new Error("Network count failed");
  await env.DB.prepare("DELETE FROM daily_network_keys WHERE day < date('now', '-1 day')").bind().run();
}
export async function recordNetworkUnique(request, env, appID) {
  try { await storeNetworkToken(env, appID, await networkToken(request, env, appID)); }
  catch { console.error("Daily network counting unavailable"); }
}

export function excludedRequest(request, env = {}) {
  const ip = request.headers.get("cf-connecting-ip");
  return request.headers.get("x-analytics-excluded") === "1" ||
    (request.headers.get("cookie") ?? "").split(";").some(part => part.trim() === "__Host-analytics_excluded=1") ||
    (!!ip && (env.ANALYTICS_EXCLUDED_IPS ?? "").split(",").map(value => value.trim()).includes(ip));
}
