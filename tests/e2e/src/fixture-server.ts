import Fastify from 'fastify';
import { fastifyTRPCPlugin } from '@trpc/server/adapters/fastify';
import { appRouter, createFixtureContext } from './fixture/trpc/router.js';
import { binaryRouter } from './fixture/trpc-binary/router.js';

export interface FixtureServer {
  port: number;
  close: () => Promise<void>;
}

export async function startFixtureServer(): Promise<FixtureServer> {
  const app = Fastify({ logger: false, maxParamLength: 5000 });
  await app.register(fastifyTRPCPlugin, {
    prefix: '/trpc',
    trpcOptions: {
      router: appRouter,
      createContext: ({ req }: { req: { headers: Record<string, string | string[] | undefined> } }) =>
        createFixtureContext(
          Array.isArray(req.headers.authorization) ? req.headers.authorization[0] : req.headers.authorization,
        ),
    },
  });
  await app.register(fastifyTRPCPlugin, {
    prefix: '/trpc-binary',
    trpcOptions: { router: binaryRouter },
  });
  await app.listen({ port: 0, host: '127.0.0.1' });
  const address = app.server.address();
  const port = typeof address === 'object' && address !== null ? address.port : 0;
  return { port, close: () => app.close() };
}
