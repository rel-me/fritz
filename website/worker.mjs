import { latestDownload } from "./public/appcast.mjs";

const ARCHIVE_PATH = /^\/updates\/(Fritz-\d+\.\d+\.\d+\.dmg)$/;

function rangeFor(header, size) {
  if (!header) return null;
  const match = /^bytes=(\d*)-(\d*)$/.exec(header);
  if (!match || (!match[1] && !match[2])) return false;
  const first = match[1] ? Number(match[1]) : null;
  const last = match[2] ? Number(match[2]) : null;
  if ((first !== null && !Number.isSafeInteger(first)) ||
      (last !== null && !Number.isSafeInteger(last))) return false;
  if (first === null) {
    if (last === 0 || size === 0) return false;
    const offset = Math.max(0, size - last);
    return { offset, length: size - offset };
  }
  if (first >= size || (last !== null && last < first)) return false;
  return { offset: first, length: Math.min(size - first, last === null ? size : last - first + 1) };
}

async function serveObject(request, bucket, key, contentType, cacheControl) {
  const metadata = await bucket.head(key);
  if (!metadata) return new Response("Not found", { status: 404 });
  const rangeHeader = request.headers.get("range");
  const range = rangeFor(rangeHeader, metadata.size);
  if (range === false) {
    return new Response(null, {
      status: 416,
      headers: { "accept-ranges": "bytes", "content-range": `bytes */${metadata.size}` },
    });
  }
  const headers = new Headers({
    "accept-ranges": "bytes",
    "cache-control": cacheControl,
    "content-type": contentType,
    "content-length": String(range ? range.length : metadata.size),
    "x-content-type-options": "nosniff",
  });
  if (metadata.httpEtag) headers.set("etag", metadata.httpEtag);
  if (range) {
    headers.set("content-range", `bytes ${range.offset}-${range.offset + range.length - 1}/${metadata.size}`);
  }
  const status = range ? 206 : 200;
  if (request.method === "HEAD") return new Response(null, { status, headers });
  const object = await bucket.get(key, range ? { range } : undefined);
  if (!object) return new Response("Not found", { status: 404 });
  return new Response(object.body, { status, headers });
}

export default {
  async fetch(request, env, ctx) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", { status: 405, headers: { allow: "GET, HEAD" } });
    }
    const path = new URL(request.url).pathname;
    // Static assets in public/ answer first; the home page links here for the current DMG.
    if (path === "/download") {
      const appcast = await env.UPDATES.get("appcast.xml");
      const latest = appcast && latestDownload(await appcast.text());
      if (!latest) return new Response("No download is available yet", { status: 404 });
      return new Response(null, {
        status: 302,
        headers: { location: `/updates/${latest.filename}`, "cache-control": "no-store" },
      });
    }
    if (path === "/appcast.xml") {
      const response = await serveObject(request, env.UPDATES, "appcast.xml", "application/xml; charset=utf-8", "no-store");
      if (request.method === "GET" && [200, 304].includes(response.status)) {
        // Store only a daily total. No requester or installation metadata is read.
        ctx.waitUntil((async () => {
          try {
            const result = await env.DB.prepare(`INSERT INTO update_check_counts (app_id, day, version, runtime, checks)
              VALUES ('dev.fritz.app', ?, 'unknown', 'release', 1)
              ON CONFLICT (app_id, day, version, runtime) DO UPDATE SET checks = checks + 1`)
              .bind(new Date().toISOString().slice(0, 10)).run();
            if (!result.success) throw new Error("D1 write failed");
          } catch {
            console.error("Fritz update-request counting failed.");
          }
        })());
      }
      return response;
    }
    const filename = ARCHIVE_PATH.exec(path)?.[1];
    if (filename) {
      return serveObject(request, env.UPDATES, `updates/${filename}`,
        "application/x-apple-diskimage", "public, max-age=31536000, immutable");
    }
    return new Response("Not found", { status: 404 });
  },
};
