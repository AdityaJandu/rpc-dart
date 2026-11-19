import { eventIterator, oc } from '@orpc/contract';
import { implement, lazy, os } from '@orpc/server';
import * as v from 'valibot';
import { z } from 'zod';

const planetSchema = z.object({ id: z.number(), name: z.string(), discoveredAt: z.date() });

export const contractRouter = oc.router({
  planet: oc.router({
    find: oc
      .route({ method: 'GET', path: '/planets/{id}' })
      .input(z.object({ id: z.number() }))
      .output(planetSchema)
      .errors({
        NOT_FOUND: { message: 'Planet not found', data: z.object({ id: z.number() }) },
        BAD_REQUEST: { message: 'bad id', data: z.string() },
      }),
    create: oc
      .input(z.object({ name: z.string() }))
      .output(planetSchema)
      .errors({
        CONFLICT: { data: z.object({ existingId: z.number() }) },
        RATE_LIMITED: { status: 429, message: 'slow down' },
      }),
    watch: oc
      .input(z.object({ id: z.number() }))
      .output(eventIterator(z.object({ tick: z.number(), at: z.date() }))),
  }),
  uploads: oc.router({
    avatar: oc
      .input(z.object({ file: z.custom<File>(), thumb: z.custom<Blob>() }))
      .output(z.object({ url: z.string() })),
    raw: oc.input(z.custom<Uint8Array>()).output(z.custom<Uint8Array>()),
    stream: oc.route({ method: 'GET' }).output(z.custom<ReadableStream<Uint8Array>>()),
  }),
  valibot: oc.router({
    echo: oc
      .input(v.object({ n: v.number(), tag: v.optional(v.string()) }))
      .output(v.object({ doubled: v.number() })),
  }),
});

const impl = implement(contractRouter);

export const appRouter = impl.router({
  planet: {
    find: impl.planet.find.handler(({ input }) => ({ id: input.id, name: 'Earth', discoveredAt: new Date() })),
    create: impl.planet.create.handler(({ input }) => ({ id: 1, name: input.name, discoveredAt: new Date() })),
    watch: impl.planet.watch.handler(async function* ({ input }) {
      yield { tick: input.id, at: new Date() };
    }),
  },
  uploads: {
    avatar: impl.uploads.avatar.handler(({ input }) => ({ url: `https://cdn.example/${input.file.name}` })),
    raw: impl.uploads.raw.handler(({ input }) => input),
    stream: impl.uploads.stream.handler(() => new ReadableStream<Uint8Array>()),
  },
  valibot: {
    echo: impl.valibot.echo.handler(({ input }) => ({ doubled: input.n * 2 })),
  },
});

export const inferredRouter = os.router({
  health: os.handler(() => ({ ok: true as const, uptime: 123 })),
  now: os.handler(() => ({ at: new Date(), big: 10n })),
  ping: os.route({ method: 'GET' }).handler(() => 'pong'),
  echo: os.input(z.object({ msg: z.string() })).handler(({ input }) => ({ msg: input.msg, len: input.msg.length })),
  counter: os.handler(async function* () {
    yield { n: 1 };
  }),
  nested: lazy(() => import('./lazy-router.js')),
});

export const notARouter = { foo: 42 };