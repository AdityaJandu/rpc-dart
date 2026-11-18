import { createJiti } from 'jiti';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
// Ephemeral port so parallel e2e runs never collide.
process.env.PORT ??= '0';
const jiti = createJiti(path.join(here, '..', 'src', 'server.ts'));
const mod = await jiti.import(path.join(here, '..', 'src', 'server.ts'));
const server = await mod.startExampleServer();
console.log(`FIXTURE_PORT=${server.port}`);
process.on('SIGTERM', async () => {
  await server.close();
  process.exit(0);
});
setInterval(() => {}, 10000);
