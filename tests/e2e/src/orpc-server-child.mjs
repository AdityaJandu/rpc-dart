import { createJiti } from 'jiti';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = fileURLToPath(new URL('.', import.meta.url));
const jiti = createJiti(path.join(here, 'orpc-server.ts'));
const mod = await jiti.import(path.join(here, 'orpc-server.ts'));
const server = await mod.startOrpcFixtureServer();
console.log(`FIXTURE_PORT=${server.port}`);
process.on('SIGTERM', async () => {
  await server.close();
  process.exit(0);
});
// keep alive
setInterval(() => {}, 10000);