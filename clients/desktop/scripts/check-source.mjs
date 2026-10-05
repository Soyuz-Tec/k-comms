import { readFileSync, readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { validateConfig } from '../src/policy.mjs';
validateConfig(JSON.parse(readFileSync(new URL('../desktop.config.json', import.meta.url))));
for (const directory of ['src', 'scripts', 'test']) for (const file of readdirSync(new URL('../' + directory + '/', import.meta.url))) {
  if (!/\.(mjs|cjs)$/.test(file)) continue;
  const result = spawnSync(process.execPath, ['--check', fileURLToPath(new URL('../' + directory + '/' + file, import.meta.url))], { stdio: 'inherit' });
  if (result.status !== 0) process.exit(1);
}
console.log('Desktop JavaScript and immutable default policy parsed; runtime and packaging not executed');
