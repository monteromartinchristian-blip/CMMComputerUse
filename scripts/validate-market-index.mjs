#!/usr/bin/env node
// Validate docs/marketplace/index.json with the host's own validator.
//
// A hand-checked JSON proves the shape the author had in mind; this proves the
// shape the installed DSH accepts, including the install target it derives.
//
//   ELECTRON_RUN_AS_NODE=1 "/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness" \
//     scripts/validate-market-index.mjs <index.json> [index-url]
import {readFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
import {createRequire} from 'node:module';

const INDEX = process.argv[2];
const URL_FOR_RESOLUTION = process.argv[3]
  || 'https://raw.githubusercontent.com/monteromartinchristian-blip/CMMComputerUse/main/docs/marketplace/index.json';

const moduleDir = '/Applications/DeepSeek Harness.app/Contents/Resources/app.asar/dsh/node_modules/@deepseek-ai/dsh-plugin-market-index/lib/index.js';
const mod = await import(pathToFileURL(moduleDir).href);
const {parseMarketIndex, marketInstallTarget} = mod;

const document = JSON.parse(readFileSync(INDEX, 'utf8'));
const parsed = parseMarketIndex(document, URL_FOR_RESOLUTION);

console.log(`index title: ${JSON.stringify(parsed.title)}`);
console.log(`plugins: ${parsed.plugins.length}`);
for (const plugin of parsed.plugins) {
  console.log(`  ${plugin.name} — ${plugin.versions.length} version(s)`);
  for (const version of plugin.versions) {
    const target = marketInstallTarget(plugin.name, version);
    console.log(`    ${version.version}  published=${version.publishTimestamp}  engines=${JSON.stringify(version.engines)}`);
    console.log(`    source=${JSON.stringify(version.source)}`);
    console.log(`    install=${JSON.stringify(target)}`);
  }
  console.log(`  category=${plugin.metadata.category} labels=${JSON.stringify(plugin.metadata.labels)}`);
  console.log(`  repository=${JSON.stringify(plugin.repository)} directory=${plugin.repository?.directory}`);
}
console.log('MARKET_INDEX_VALID=PASS');
