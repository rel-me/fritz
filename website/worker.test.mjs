import assert from "node:assert/strict";
import test from "node:test";
import worker from "./worker.mjs";

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
  const response = await download(appcast(item("0.1.1", 2, "beta"), item("0.1.2", 3, "beta"), item("0.2.0", 5, "dev")));
  assert.equal(response.status, 302);
  assert.equal(response.headers.get("location"), "/updates/Fritz-0.1.2.dmg");
});

test("download ignores Dev builds and unexpected archive URLs", async () => {
  assert.equal((await download(appcast(item("0.2.0", 5, "dev")))).status, 404);
  const foreign = item("0.1.1", 2).replace("/updates/Fritz-0.1.1.dmg", "/files/Fritz-0.1.1.dmg");
  assert.equal((await download(appcast(foreign))).status, 404);
  assert.equal((await download({ UPDATES: bucket({}) })).status, 404);
});
