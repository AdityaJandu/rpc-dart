import { createJiti } from 'jiti';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = '/Users/adityajandu/Coding/rpc-dart/tests/e2e/src';
const jiti = createJiti(path.join(here, 'fixture-server.ts'));
const mod = await jiti.import(path.join(here, 'fixture-server.ts'));
const server = await mod.startFixtureServer();
console.log(`FIXTURE_PORT=${server.port}`);
process.on('SIGTERM', async () => {
  await server.close();
  process.exit(0);
});
// keep alive
setInterval(() => {}, 10000);
