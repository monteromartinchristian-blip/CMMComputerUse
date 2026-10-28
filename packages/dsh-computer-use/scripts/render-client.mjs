#!/usr/bin/env node
// Renders dist/client.js from client.template.js + runtime.mjs + locale/*.json.
//
// The DSH Client module loader takes one file through
// `window.__ModuleLoader__.load({factory})`; it does not resolve JSON imports
// the way a bundler would. So the shipped client is produced here, from one
// source, deterministically: the same three inputs must always yield the same
// bytes. `--check` fails when dist/client.js is stale, which is what keeps a
// published tarball from carrying a half-rendered template.
import {readFileSync, writeFileSync, mkdirSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const TEMPLATE = join(ROOT, 'client.template.js');
const RUNTIME = join(ROOT, 'runtime.mjs');
const LOCALES = ['en', 'es'];
const OUT = join(ROOT, 'dist', 'client.js');

export function render() {
  const template = readFileSync(TEMPLATE, 'utf8');
  // `export` keywords are stripped: the factory body is a plain function, and
  // the names stay in its scope.
  const runtime = readFileSync(RUNTIME, 'utf8').replace(/\bexport (?=(?:const|function|async function) )/g, '');
  const dictionaries = Object.fromEntries(LOCALES.map(lang => [
    lang,
    JSON.parse(readFileSync(join(ROOT, 'locale', `${lang}.json`), 'utf8')).panel,
  ]));
  const markers = ['/*__CMM_RUNTIME__*/', '/*__CMM_LOCALES__*/'];
  for (const marker of markers) {
    if (!template.includes(marker)) throw new Error(`template lost its marker: ${marker}`);
  }
  if (template.includes('/*__CMM_TEST_IMAGE__*/')) throw new Error('template still carries the removed test-image marker');
  return template
    .replace('/*__CMM_RUNTIME__*/', () => runtime)
    .replace('/*__CMM_LOCALES__*/', () => JSON.stringify(dictionaries));
}

const rendered = render();
if (process.argv.includes('--check')) {
  let current = '';
  try { current = readFileSync(OUT, 'utf8'); } catch {}
  if (current !== rendered) {
    console.error('dist/client.js is stale; run: node scripts/render-client.mjs');
    process.exit(1);
  }
  console.log(`dist/client.js up to date (${Buffer.byteLength(rendered)} bytes)`);
} else {
  mkdirSync(dirname(OUT), {recursive: true});
  writeFileSync(OUT, rendered);
  console.log(`wrote dist/client.js (${Buffer.byteLength(rendered)} bytes)`);
}
