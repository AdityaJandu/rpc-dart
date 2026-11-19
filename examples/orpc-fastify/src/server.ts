import Fastify from 'fastify';
import { eventIterator, oc } from '@orpc/contract';
import { implement, withEventMeta } from '@orpc/server';
import { RPCHandler } from '@orpc/server/fastify';
import { z } from 'zod';

const PORT = Number(process.env.PORT ?? 8788);
const HOST = process.env.HOST?.trim() || '127.0.0.1';
const RPC_PREFIX = '/rpc';

const planetSchema = z.object({
  id: z.number(),
  name: z.string(),
  discoveredAt: z.date(),
  mass: z.bigint(),
});

export const contract = oc.router({
  planet: oc.router({
    find: oc
      .route({ method: 'GET' })
      .input(z.object({ id: z.number() }))
      .output(planetSchema)
      .errors({ NOT_FOUND: { data: z.object({ id: z.number() }) } }),
    create: oc.input(z.object({ name: z.string() })).output(planetSchema),
  }),
  uploads: oc.router({
    avatar: oc
      .input(z.object({ file: z.custom<File>(), note: z.string() }))
      .output(z.object({ name: z.string(), size: z.number(), note: z.string() })),
  }),
  files: oc.router({
    download: oc.route({ method: 'GET' }).output(z.custom<File>()),
    stream: oc.route({ method: 'GET' }).output(z.custom<ReadableStream<Uint8Array>>()),
  }),
  streams: oc.router({
    ticks: oc
      .input(z.object({ count: z.number() }))
      .output(eventIterator(z.object({ tick: z.number(), at: z.date() }))),
  }),
});

export interface ExampleContext {
  authorization?: string;
}

const impl = implement(contract).$context<ExampleContext>();

const earth = {
  id: 1,
  name: 'Earth',
  discoveredAt: new Date('2022-01-01T00:00:00.000Z'),
  mass: 5972n,
};

export const appRouter = impl.router({
  planet: {
    find: impl.planet.find.handler(({ input, errors }) => {
      if (input.id !== 1) throw errors.NOT_FOUND({ data: { id: input.id } });
      return earth;
    }),
    create: impl.planet.create.handler(({ input }) => ({
      id: 2,
      name: input.name,
      discoveredAt: new Date(),
      mass: 1n,
    })),
  },
  uploads: {
    avatar: impl.uploads.avatar.handler(async ({ input }) => ({
      name: input.file.name,
      size: input.file.size,
      note: input.note,
    })),
  },
  files: {
    download: impl.files.download.handler(
      () =>
        new File([new Uint8Array([10, 20, 30, 40])], 'earth.png', {
          type: 'image/png',
        }),
    ),
    stream: impl.files.stream.handler(
      () =>
        new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(new Uint8Array([1, 2]));
            controller.enqueue(new Uint8Array([3]));
            controller.close();
          },
        }),
    ),
  },
  streams: {
    ticks: impl.streams.ticks.handler(async function* ({ input, lastEventId }) {
      const start = lastEventId !== undefined ? Number(lastEventId) + 1 : 0;
      for (let i = start; i < input.count; i++) {
        yield withEventMeta({ tick: i, at: new Date() }, { id: String(i) });
        await new Promise((resolve) => setTimeout(resolve, 200));
      }
    }),
  },
});

export async function startExampleServer(): Promise<{
  port: number;
  close: () => Promise<void>;
}> {
  const app = Fastify({ logger: false });
  // Leave multipart bodies unparsed so oRPC reads req.raw itself.
  app.addContentTypeParser(
    'multipart/form-data',
    (_req, _payload, done) => done(null, undefined),
  );
  const handler = new RPCHandler(appRouter);
  app.route({
    method: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
    url: `${RPC_PREFIX}/*`,
    handler: async (req, reply) => {
      const { matched } = await handler.handle(req, reply, {
        prefix: RPC_PREFIX,
        context: {
          authorization:
            typeof req.headers.authorization === 'string'
              ? req.headers.authorization
              : undefined,
        },
      });
      if (!matched) reply.code(404).send({ error: 'no procedure matched' });
    },
  });
  app.get('/health', async () => ({ ok: true }));
  await app.listen({ port: PORT, host: HOST });
  const address = app.server.address();
  const port = typeof address === 'object' && address !== null ? address.port : PORT;
  return { port, close: () => app.close() };
}

const isDirectRun =
  process.argv[1] && import.meta.url === `file://${process.argv[1]}`;
if (isDirectRun) {
  const server = await startExampleServer();
  console.log(`oRPC example server listening on http://${HOST}:${server.port}${RPC_PREFIX}`);
}