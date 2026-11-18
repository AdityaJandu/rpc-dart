// Subscription extraction fixture: all three tRPC v11 subscription output
// shapes (async generator, tracked() generator, observable) plus a generator
// that yields nothing. Relative imports use .js extensions so this compiles
// under both bundler and NodeNext tsconfigs.
import { initTRPC, tracked } from '@trpc/server';
import { observable } from '@trpc/server/observable';
import superjson from 'superjson';
import {
  ActivityInputSchema,
  type StatusUpdate,
  type UserEvent,
} from './schemas.js';

export interface SubsContext {
  user: { id: string } | null;
}

export type SubsMeta = { access: 'public' | 'authenticated' };

const t = initTRPC
  .context<SubsContext>()
  .meta<SubsMeta>()
  .create({ transformer: superjson });

const publicProcedure = t.procedure.meta({ access: 'public' });

// Never-resolving promise: extraction only inspects types, never consumes the stream.
const pause = (): Promise<void> => new Promise(() => {});

interface ServerTick {
  tick: number;
  serverTime: Date;
}

function nextStatus(down: boolean): StatusUpdate {
  return down
    ? { kind: 'down', reason: 'demo outage' }
    : { kind: 'up', since: new Date() };
}

async function* tickCounter(): AsyncGenerator<number> {
  let i = 0;
  while (true) {
    yield i;
    i++;
    await pause();
  }
}

export const counterRouter = t.router({
  onValue: publicProcedure.subscription(async function* () {
    yield* tickCounter();
  }),
});

export const streamsRouter = t.router({
  onServerTick: publicProcedure.subscription(async function* () {
    let tick = 0;
    while (true) {
      const event: ServerTick = { tick, serverTime: new Date() };
      yield event;
      tick++;
      await pause();
    }
  }),

  onStatusFeed: publicProcedure.subscription(async function* () {
    let down = false;
    while (true) {
      // Function return keeps the yield type the full StatusUpdate union
      // (a const initializer would const-narrow to one member).
      const status = nextStatus(down);
      yield status;
      down = !down;
      await pause();
    }
  }),

  onActivity: publicProcedure
    .input(ActivityInputSchema)
    .subscription(async function* () {
      let i = 0;
      while (true) {
        yield tracked(String(i), {
          messageId: `m${i}`,
          text: 'demo event',
          createdAt: new Date(),
        });
        i++;
        await pause();
      }
    }),

  onUserEvent: publicProcedure.subscription(() => {
    return observable<UserEvent>((emit) => {
      emit.next({ userId: 'u1', action: 'join', at: new Date() });
      return () => {};
    });
  }),

  onDrained: publicProcedure.subscription(
    async function* (): AsyncGenerator<never, void> {
      // Completes without ever yielding a concrete value.
    },
  ),
});

export const appRouter = t.router({
  counter: counterRouter,
  streams: streamsRouter,
});

export type AppRouter = typeof appRouter;
