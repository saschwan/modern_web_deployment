// Simple tests for the static site, run with `npm test` locally and in CI.
// They use only Node's built-in test runner (node:test), so there is nothing
// extra to learn. HTML syntax itself is checked separately by html-validate.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const siteDir = join(dirname(fileURLToPath(import.meta.url)), "..", "site");
const read = (file) => readFileSync(join(siteDir, file), "utf8");

test("index.html exists (CloudFront serves it as the default root object)", () => {
  assert.ok(existsSync(join(siteDir, "index.html")));
});

test("404.html exists (CloudFront serves it for missing pages)", () => {
  assert.ok(existsSync(join(siteDir, "404.html")));
});

test("start page says hello", () => {
  assert.match(read("index.html"), /Hello, world/);
});

test("every page has a non-empty <title>", () => {
  for (const file of readdirSync(siteDir).filter((f) => f.endsWith(".html"))) {
    assert.match(read(file), /<title>[^<]+<\/title>/, `${file} has no title`);
  }
});

test("every local link and asset points to a file that exists", () => {
  for (const file of readdirSync(siteDir).filter((f) => f.endsWith(".html"))) {
    const refs = [...read(file).matchAll(/(?:href|src)="([^"]+)"/g)].map((m) => m[1]);
    for (const ref of refs) {
      if (/^(https?:|mailto:|#)/.test(ref)) continue; // external links are not checked
      const path = ref === "/" ? "index.html" : ref.replace(/^\//, "");
      assert.ok(existsSync(join(siteDir, path)), `${file} links to missing ${ref}`);
    }
  }
});
