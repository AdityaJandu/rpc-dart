import Fastify from 'fastify';
import { RPCHandler } from '@orpc/server/fastify';
import { liveRouter } from './fixture/orpc-live/router.js';

export interface OrpcFixtureServer {
  port: number;
  close: () => Promise<void>;
}

export async function startOrpcFixtureServer(): Promise<OrpcFixtureServer> {
  const app = Fastify({ logger: false });
  // Leave multipart bodies unparsed so @orpc/server reads req.raw itself
  // (the standard-server body parser handles the indexed file maps).
  app.addContentTypeParser(
    'multipart/form-data',
    (_req, _payload, done) => done(null, undefined),
  );
  const handler = new RPCHandler(liveRouter);
  app.route({
    method: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
    url: '/rpc/*',
    handler: async (req, reply) => {
      const { matched } = await handler.handle(req, reply, {
        prefix: '/rpc',
        context: {
          authorization:
            typeof req.headers.authorization === 'string'
              ? req.headers.authorization
              : undefined,
        },
      });
      if (!matched) {
        reply.code(404).send({ error: 'no procedure matched' });
      }
    },
  });
  await app.listen({ port: 0, host: '127.0.0.1' });
  const address = app.server.address();
  const port = typeof address === 'object' && address !== null ? address.port : 0;
  return { port, close: () => app.close() };
}