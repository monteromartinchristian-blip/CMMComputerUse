#!/usr/bin/env node
// Validates the published surface of this package without installing it.
//
// What it proves, and nothing more:
//   * the manifest declares a DSH bundle and the exports DSH reads;
//   * every entry in `files` matches at least one file (a stale `files` list is
//     how a tarball loses a module that only fails at load time);
//   * the adapter that the patch launches exists and is executable;
//   * dist/client.js is the render of the current template;
//   * no published file carries an absolute personal path.
import {readFileSync, existsSync, statSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {dirname, join, relative} from 'node:path';
import {fileURLToPath} from 'node:url';
import {globSync} from 'node:fs';

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const failures = [];
const check = (ok, message) => { if (!ok) failures.push(message); };

const manifest = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8'));
check(manifest.name === '@cmm/dsh-computer-use', `unexpected name: ${manifest.name}`);
check(/^\d+\.\d+\.\d+$/.test(manifest.version), `version is not plain semver: ${manifest.version}`);
check(manifest.private !== true, 'package must not be private to publish');
check(manifest.dsh?.bundle?.patch === './cordis.patch.yml', 'dsh.bundle.patch is not ./cordis.patch.yml');
check(typeof manifest.engines?.dsh === 'string' && manifest.engines.dsh.length > 0, 'engines.dsh is not declared');
check(manifest.exports?.['./package.json'] === './package.json', 'package.json must stay exported: the patch resolves it');
check(manifest.exports?.['./client'] === './dist/client.js', 'exports ./client must be the rendered client');
check(manifest.exports?.['./icon'] === './icon.svg', 'exports ./icon is required for Plugin Manager metadata');
check(Array.isArray(manifest.files) && manifest.files.length > 0, 'files is empty');

for (const pattern of manifest.files ?? []) {
  const matches = globSync(pattern, {cwd: ROOT});
  check(matches.length > 0, `files entry matches nothing: ${pattern}`);
}

const serve = join(ROOT, 'adapter', 'serve.sh');
check(existsSync(serve), 'adapter/serve.sh is missing');
if (existsSync(serve)) check((statSync(serve).mode & 0o111) !== 0, 'adapter/serve.sh is not executable');

const patchPath = join(ROOT, 'cordis.patch.yml');
const patch = readFileSync(patchPath, 'utf8');
check(patch.includes("name: \"@deepseek-ai/dsh-mcp-client\""), 'patch does not insert the shipped MCP client');
check(patch.includes('createRequire(baseUrl)'), 'patch does not resolve its paths from the profile');
check(patch.includes('--mode'), 'patch does not pin the interaction mode');
check(patch.includes('"background"'), 'patch does not pin background mode');
check(!/\/Users\/[^/\s]+/.test(patch), 'patch carries an absolute personal path');

execFileSync(process.execPath, [join(ROOT, 'scripts', 'render-client.mjs'), '--check'], {stdio: 'inherit'});

const published = globSync('{index.js,runtime.mjs,dist/**/*.js,locale/*.json,adapter/**/*.py,adapter/serve.sh,icon.svg,cordis.patch.yml,README.md,CHANGELOG.md}',
  {cwd: ROOT, withFileTypes: false}).filter(file => !file.endsWith('/'));
for (const file of published) {
  const text = readFileSync(join(ROOT, file), 'utf8');
  check(!/\/Users\/[A-Za-z0-9._-]+/.test(text), `personal absolute path in ${file}`);
  check(!text.includes('__CMM_'), `unrendered marker in ${file}`);
}

if (failures.length) {
  for (const failure of failures) console.error(`FAIL ${failure}`);
  process.exit(1);
}
console.log(`OK manifest (${published.length} published files checked)`);
console.log(`files checked: ${relative(ROOT, ROOT) || '.'}`);
