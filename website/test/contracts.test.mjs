import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const websiteDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repositoryDirectory = resolve(websiteDirectory, "..");
const publicDirectory = join(websiteDirectory, "public");
const indexPath = join(publicDirectory, "index.html");

function read(path) {
  return readFileSync(path, "utf8");
}

function filesUnder(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      return filesUnder(path);
    }
    return [path];
  });
}

test("the website uses the README Homebrew quick start", () => {
  const readme = read(join(repositoryDirectory, "README.md"));
  const quickStart = readme.match(/## Quick start[\s\S]*?```sh\n([\s\S]*?)\n```/);
  assert.ok(quickStart, "README quick start commands were not found");

  const html = read(indexPath);
  const websiteCommands = html.match(/<pre[^>]*data-install-command[^>]*><code>([\s\S]*?)<\/code><\/pre>/);
  assert.ok(websiteCommands, "website install commands were not found");
  assert.equal(websiteCommands[1].trim(), quickStart[1].trim());
});

test("the website states the Package.swift macOS minimum", () => {
  const packageManifest = read(join(repositoryDirectory, "Package.swift"));
  const minimumVersion = packageManifest.match(/\.macOS\(\.v(\d+)\)/);
  assert.ok(minimumVersion, "Package.swift macOS minimum was not found");
  assert.match(read(indexPath), new RegExp(`macOS ${minimumVersion[1]} or later`));
});

test("local page references resolve inside the public directory", () => {
  for (const page of [indexPath, join(publicDirectory, "404.html")]) {
    const html = read(page);
    for (const [, attribute, reference] of html.matchAll(/\b(href|poster|src)=["']([^"']+)["']/g)) {
      if (reference.startsWith("#") || /^[a-z][a-z\d+.-]*:/i.test(reference)) {
        continue;
      }
      const cleanReference = reference.split(/[?#]/, 1)[0];
      if (cleanReference === "/") {
        assert.ok(existsSync(indexPath), `${attribute}=${reference} does not resolve`);
        continue;
      }
      const resolvedPath = cleanReference.startsWith("/")
        ? join(publicDirectory, cleanReference)
        : resolve(dirname(page), cleanReference);
      assert.ok(
        resolvedPath === publicDirectory || resolvedPath.startsWith(`${publicDirectory}/`),
        `${attribute}=${reference} leaves public`,
      );
      assert.ok(existsSync(resolvedPath), `${attribute}=${reference} does not resolve`);
    }
  }
});

test("browser-loaded resources are local", () => {
  const references = [];
  for (const page of [indexPath, join(publicDirectory, "404.html")]) {
    const html = read(page);
    for (const [, attribute, reference] of html.matchAll(/\b(poster|src)=["']([^"']+)["']/g)) {
      references.push([attribute, reference]);
    }
    for (const [, value] of html.matchAll(/\bsrcset=["']([^"']+)["']/g)) {
      for (const candidate of value.split(",")) {
        references.push(["srcset", candidate.trim().split(/\s+/, 1)[0]]);
      }
    }
    for (const [tag] of html.matchAll(/<link\b[^>]*>/gi)) {
      const rel = tag.match(/\brel=["']([^"']+)["']/i)?.[1].toLowerCase().split(/\s+/);
      const loadedRelations = [
        "apple-touch-icon",
        "dns-prefetch",
        "icon",
        "manifest",
        "mask-icon",
        "modulepreload",
        "preconnect",
        "prefetch",
        "preload",
        "prerender",
        "stylesheet",
      ];
      if (!rel?.some((value) => loadedRelations.includes(value))) {
        continue;
      }
      const href = tag.match(/\bhref=["']([^"']+)["']/i)?.[1];
      if (href) {
        references.push(["link", href]);
      }
    }
  }

  const css = read(join(publicDirectory, "styles.css"));
  for (const [, reference] of css.matchAll(/url\(\s*["']?([^"')]+)["']?\s*\)/gi)) {
    references.push(["CSS url", reference]);
  }
  for (const [, reference] of css.matchAll(/@import\s+["']([^"']+)["']/gi)) {
    references.push(["CSS import", reference]);
  }

  for (const [source, reference] of references) {
    assert.doesNotMatch(reference, /^(?:[a-z][a-z\d+.-]*:|\/\/)/i, `${source} must be local`);
  }
});

test("canonical metadata identifies the production URL", () => {
  const html = read(indexPath);
  assert.match(html, /<link rel="canonical" href="https:\/\/getvindu\.app\/">/);
  assert.match(html, /<meta property="og:url" content="https:\/\/getvindu\.app\/">/);
});

test("the hero identifies the product without a marketing slogan", () => {
  const html = read(indexPath);
  assert.match(html, /<h1>Vindu is a dynamic tiling window manager for macOS\.<\/h1>/);
  assert.doesNotMatch(html, /New windows take their place/i);
});

test("the website does not include screen recordings", () => {
  const html = read(indexPath);
  assert.doesNotMatch(html, /<(?:source|video)\b/i);
  assert.equal(
    filesUnder(join(publicDirectory, "assets")).some((path) => /\.(?:apng|gif|m4v|mov|mp4|ogv|webm)$/i.test(path)),
    false,
  );
});

test("technical sections appear in order", () => {
  const html = read(indexPath);
  const sectionIds = ["overview", "grid", "keyboard", "configuration", "macos", "install"];
  let previousPosition = -1;
  for (const sectionId of sectionIds) {
    const position = html.indexOf(`id="${sectionId}"`);
    assert.ok(position > previousPosition, `${sectionId} is missing or out of order`);
    previousPosition = position;
  }
});

test("section labels do not use eyebrows or leading-zero numbers", () => {
  const html = read(indexPath);
  assert.doesNotMatch(html, /\b(?:eyebrow|section-number)\b/);
  assert.doesNotMatch(html, />0[1-9]</);
});

test("public copy excludes stale names and unsupported claims", () => {
  const text = filesUnder(publicDirectory)
    .filter((path) => [".css", ".html", ".js", ".txt", ".xml"].includes(extname(path)))
    .map(read)
    .join("\n");
  assert.doesNotMatch(text, /vindu\.conf/i);
  assert.doesNotMatch(text, /macland/i);
  assert.doesNotMatch(text, /open source/i);
});
