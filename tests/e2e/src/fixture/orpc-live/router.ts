import { eventIterator, oc } from '@orpc/contract';
import { implement, withEventMeta } from '@orpc/server';
import { z } from 'zod';

const planetSchema = z.object({
  id: z.number(),
  name: z.string(),
  discoveredAt: z.date(),
  mass: z.bigint(),
});

export const liveContract = oc.router({
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
    bundle: oc
      .route({ method: 'GET' })
      .output(z.object({ name: z.string(), avatar: z.custom<File>() })),
  }),
  streams: oc.router({
    ticks: oc
      .input(z.object({ count: z.number() }))
      .output(eventIterator(z.object({ tick: z.number(), at: z.date() }))),
  }),
  secure: oc.router({
    me: oc.output(z.object({ id: z.string() })).errors({ UNAUTHORIZED: {} }),
  }),
});

export interface LiveContext {
  authorization?: string;
}

const impl = implement(liveContract).$context<LiveContext>();

const earth = {
  id: 1,
  name: 'Earth',
  discoveredAt: new Date('2022-01-01T00:00:00.000Z'),
  mass: 5972n,
};

export const liveRouter = impl.router({
  planet: {
    find: impl.planet.find.handler(({ input, errors }) => {
      if (input.id !== 1) {
        throw errors.NOT_FOUND({ data: { id: input.id } });
      }
      return earth;
    }),
    create: impl.planet.create.handler(({ input }) => ({
      id: 2,
      name: input.name,
      discoveredAt: new Date('2026-01-01T00:00:00.000Z'),
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
      () => new File([new Uint8Array([10, 20, 30, 40])], 'earth.png', { type: 'image/png' }),
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
    bundle: impl.files.bundle.handler(() => ({
      name: 'Earth',
      avatar: new File([new Uint8Array([9])], 'a.png', { type: 'image/png' }),
    })),
  },
  streams: {
    ticks: impl.streams.ticks.handler(async function* ({ input, lastEventId }) {
      const start = lastEventId !== undefined ? Number(lastEventId) + 1 : 0;
      for (let i = start; i < input.count; i++) {
        yield withEventMeta(
          { tick: i, at: new Date('2026-01-01T00:00:00.000Z') },
          { id: String(i) },
        );
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
    }),
  },
  secure: {
    me: impl.secure.me.handler(({ context, errors }) => {
      if (context.authorization !== 'Bearer u1') {
        throw errors.UNAUTHORIZED();
      }
      return { id: 'u1' };
    }),
  },
});