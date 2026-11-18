import assert from "node:assert/strict";
import test, { after } from "node:test";
import { DatabaseSync } from "node:sqlite";
import siteWorker from "./worker.mjs";

const db = new DatabaseSync(":memory:");
db.exec(`CREATE TABLE update_check_counts (
  app_id TEXT NOT NULL, day TEXT NOT NULL, version TEXT NOT NULL,
  runtime TEXT NOT NULL, checks INTEGER NOT NULL,
  PRIMARY KEY (app_id, day, version, runtime))`);
db.exec(`CREATE TABLE daily_network_keys (app_id TEXT NOT NULL, day TEXT NOT NULL, network_hash TEXT NOT NULL, PRIMARY KEY(app_id, day, network_hash));
CREATE TABLE daily_network_counts (app_id TEXT NOT NULL, day TEXT NOT NULL, networks INTEGER NOT NULL, PRIMARY KEY(app_id, day));
CREATE TRIGGER daily_network_observed AFTER INSERT ON daily_network_keys BEGIN
INSERT INTO daily_network_counts VALUES (NEW.app_id, NEW.day, 1) ON CONFLICT(app_id, day) DO UPDATE SET networks=networks+1; END;`);
after(() => db.close());
const DB = { prepare(sql) { return { bind(...values) { return { async run() {
  db.prepare(sql).run(...values);
  return { success: true };
} }; } }; } };
const worker = { async fetch(request, env) {
  const pending = [];
  const response = await siteWorker.fetch(request, { DB, ...env }, {
    waitUntil(promise) { pending.push(promise); },
  });
  await Promise.all(pending);
  return response;
} };

function bucket(objects) {
  return {
    async head(key) {
      const bytes = objects[key];
      return bytes ? { size: bytes.length, httpEtag: '"test"' } : null;
    },
    async get(key, options) {
      const bytes = objects[key];
      if (!bytes) return null;
      const range = options?.range;
      const body = range ? bytes.slice(range.offset, range.offset + range.length) : bytes;
      return { body, async text() { return new TextDecoder().decode(body); } };
    },
  };
}

const env = {
  UPDATES: bucket({
    "appcast.xml": new TextEncoder().encode("<rss/>"),
    "updates/Fritz-0.1.1.dmg": new TextEncoder().encode("0123456789"),
  }),
};

test("serves Fritz's appcast and versioned archive", async () => {
  const feed = await worker.fetch(new Request("https://fritz.rel.me/appcast.xml"), env);
  assert.equal(feed.status, 200);
  assert.equal(feed.headers.get("cache-control"), "no-store");
  assert.equal(await feed.text(), "<rss/>");

  const archive = await worker.fetch(new Request("https://fritz.rel.me/updates/Fritz-0.1.1.dmg"), env);
  assert.equal(archive.status, 200);
  assert.equal(archive.headers.get("content-length"), "10");
  assert.equal(await archive.text(), "0123456789");
});

test("supports HEAD and byte ranges for archive downloads", async () => {
  const url = "https://fritz.rel.me/updates/Fritz-0.1.1.dmg";
  const head = await worker.fetch(new Request(url, { method: "HEAD" }), env);
  assert.equal(head.status, 200);
  assert.equal(head.headers.get("content-length"), "10");
  const partial = await worker.fetch(new Request(url, { headers: { range: "bytes=2-4" } }), env);
  assert.equal(partial.status, 206);
  assert.equal(partial.headers.get("content-range"), "bytes 2-4/10");
  assert.equal(await partial.text(), "234");
  const invalid = await worker.fetch(new Request(url, { headers: { range: "bytes=99-" } }), env);
  assert.equal(invalid.status, 416);
});

test("rejects other artifacts and mutation requests", async () => {
  assert.equal((await worker.fetch(new Request("https://fritz.rel.me/updates/REL-0.1.1.dmg"), env)).status, 404);
  assert.equal((await worker.fetch(new Request("https://fritz.rel.me/updates/Fritz-0.1.1.dmg", { method: "POST" }), env)).status, 405);
});

function item(version, build, channel) {
  return `<item><title>${version}</title>${channel ? `<sparkle:channel>${channel}</sparkle:channel>` : ""}
    <sparkle:version>${build}</sparkle:version><sparkle:shortVersionString>${version}</sparkle:shortVersionString>
    <enclosure url="https://fritz.rel.me/updates/Fritz-${version}.dmg" length="10" type="application/octet-stream" sparkle:edSignature="c2ln"/></item>`;
}

function appcast(...items) {
  const xml = `<?xml version="1.0" standalone="yes"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>Fritz</title>${items.join("")}</channel></rss>`;
  return { UPDATES: bucket({ "appcast.xml": new TextEncoder().encode(xml) }) };
}

async function download(env) {
  return worker.fetch(new Request("https://fritz.rel.me/download"), env);
}

test("download redirects to the newest Release archive", async () => {
  const response = await download(appcast(item("0.1.3", 4, "beta"), item("0.1.2", 3), item("0.1.1", 2)));
  assert.equal(response.status, 302);
  assert.equal(response.headers.get("location"), "/updates/Fritz-0.1.2.dmg");
  assert.equal(response.headers.get("cache-control"), "no-store");
});

test("download falls back to the newest Beta archive before any Release", async () => {
  const response = await download(appcast(item("0.1.1", 2, "beta"), item("0.1.2", 3, "beta"), item("0.2.0", 5, "staging")));
  assert.equal(response.status, 302);
  assert.equal(response.headers.get("location"), "/updates/Fritz-0.1.2.dmg");
});

test("download ignores Staging builds and unexpected archive URLs", async () => {
  assert.equal((await download(appcast(item("0.2.0", 5, "staging")))).status, 404);
  const foreign = item("0.1.1", 2).replace("/updates/Fritz-0.1.1.dmg", "/files/Fritz-0.1.1.dmg");
  assert.equal((await download(appcast(foreign))).status, 404);
  assert.equal((await download({ UPDATES: bucket({}) })).status, 404);
});

test("counts only successful appcast GETs as atomic daily totals without request metadata", async () => {
  db.exec("DELETE FROM update_check_counts");
  const get = (path, init, environment = env) => worker.fetch(new Request(`https://fritz.rel.me${path}`, init), environment);
  const responses = await Promise.all(Array.from({ length: 4 }, () => get("/appcast.xml", { headers: {
    "user-agent": "Fritz/99.0 Sparkle/2", "x-installation-id": "private-id", "x-fritz-app-version": "99.0",
  } })));
  for (const response of responses) {
    assert.equal(response.status, 200);
    assert.equal(await response.text(), "<rss/>");
  }
  await get("/appcast.xml", { method: "HEAD" });
  await get("/appcast.xml", { method: "POST" });
  await get("/appcast.xml", { headers: { range: "bytes=0-1" } });
  await get("/appcast.xml", undefined, { UPDATES: bucket({}) });
  await get("/updates/Fritz-0.1.1.dmg");
  await get("/download");
  assert.deepEqual(db.prepare("SELECT * FROM update_check_counts").all().map(row => ({ ...row })), [{
    app_id: "dev.fritz.app", day: new Date().toISOString().slice(0, 10), version: "unknown", runtime: "release", checks: 4,
  }]);
});

test("counter failures leave signed feed bytes and response headers intact", async t => {
  const errors = t.mock.method(console, "error", () => {});
  for (const DB of [
    { prepare() { throw new Error("unavailable"); } },
    { prepare() { return { bind() { return { run: async () => ({ success: false }) }; } }; } },
  ]) {
    const response = await worker.fetch(new Request("https://fritz.rel.me/appcast.xml", { headers: { "user-agent": "Fritz/0.1.10 Sparkle/2" } }), { ...env, DB });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.equal(await response.text(), "<rss/>");
  }
  assert.equal(errors.mock.callCount(), 2);
});

test("Debug, browser, prefetch and excluded testing requests serve feed bytes without counting", async () => {
  db.exec("DELETE FROM update_check_counts");
  for (const headers of [ {}, { "user-agent": "FritzDebug/0.1.10 Sparkle/2" },
    { "user-agent": "Fritz/0.1.10 Sparkle/2", "x-fritz-runtime": "debug" },
    { "user-agent": "Fritz/0.1.10 Sparkle/2", "x-analytics-excluded": "1" },
    { "user-agent": "Fritz/0.1.10 Sparkle/2", cookie: "__Host-analytics_excluded=1" },
    { "user-agent": "Fritz/0.1.10 Sparkle/2", purpose: "prefetch" },
    { "user-agent": "Fritz/0.1.10 Sparkle/2", "cf-connecting-ip": "192.0.2.1" },
  ]) {
    const response = await worker.fetch(new Request("https://fritz.rel.me/appcast.xml", { headers }), { ...env, ANALYTICS_EXCLUDED_IPS: "192.0.2.1" });
    assert.equal(await response.text(), "<rss/>");
  }
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM update_check_counts").get().n, 0);
  const result = await worker.fetch(new Request("https://fritz.rel.me/analytics/exclude", { method: "POST", headers: { origin: "https://fritz.rel.me" } }), env);
  assert.equal(result.status, 303);
  assert.match(result.headers.get("set-cookie"), /^__Host-analytics_excluded=1;/);
  assert.equal((await worker.fetch(new Request("https://fritz.rel.me/analytics/exclude", { method: "POST", headers: { origin: "https://other.example" } }), env)).status, 403);
});

test("release checks count daily networks without retaining the raw IP", async () => {
  const headers = { "user-agent": "Fritz/0.1.10 Sparkle/2", "cf-connecting-ip": "192.0.2.1" };
  const environment = { ...env, ANALYTICS_UNIQUES_KEY: "test-only-secret" };
  for (let i = 0; i < 2; i++) await worker.fetch(new Request("https://fritz.rel.me/appcast.xml", { headers }), environment);
  assert.equal(db.prepare("SELECT networks FROM daily_network_counts").get().networks, 1);
  assert.match(db.prepare("SELECT network_hash FROM daily_network_keys").get().network_hash, /^[0-9a-f]{64}$/);
  assert.ok(!JSON.stringify(db.prepare("SELECT * FROM daily_network_keys").all()).includes("192.0.2.1"));
});
