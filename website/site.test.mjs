import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import test from "node:test";

const WORKER_ROUTES = new Set(["/download", "/appcast.xml"]);
const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");

test("Wrangler serves the home page from public/", () => {
  assert.equal(JSON.parse(read("wrangler.jsonc")).assets.directory, "./public");
  assert.ok(existsSync(new URL("public/index.html", import.meta.url)));
});

test("home page references only published files and Worker routes", () => {
  const html = read("public/index.html");
  const css = read("public/styles.css");
  const paths = [
    ...[...html.matchAll(/(?:href|src)="(\/[^"#]*)"/g)].map((match) => match[1]),
    ...[...css.matchAll(/url\("(\/[^"]+)"\)/g)].map((match) => match[1]),
    ...[...read("public/site.mjs").matchAll(/from "(\/[^"]+)"/g)].map((match) => match[1]),
  ];
  assert.ok(paths.includes("/download"));
  for (const path of new Set(paths)) {
    if (path === "/" || WORKER_ROUTES.has(path)) continue;
    assert.ok(existsSync(new URL(`public${path}`, import.meta.url)), `missing public${path}`);
  }
  for (const anchor of html.matchAll(/href="#([^"]+)"/g)) {
    assert.match(html, new RegExp(`id="${anchor[1]}"`), `missing #${anchor[1]}`);
  }
});

test("home page avoids inline scripts and styles blocked by its CSP", () => {
  const html = read("public/index.html");
  assert.match(read("public/_headers"), /script-src 'self'; style-src 'self'/);
  assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)[^>]*>/);
  assert.doesNotMatch(html, /\sstyle="|<style/);
});
