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
      return { body: range ? bytes.slice(range.offset, range.offset + range.length) : bytes };
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
