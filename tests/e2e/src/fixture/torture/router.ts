import { initTRPC } from '@trpc/server';
import { z } from 'zod';
import superjson from 'superjson';
import {
  TortureInputSchema,
  type TortureOutput,
} from './schemas.js';

export interface TortureContext {
  user: { id: string } | null;
}

const t = initTRPC.context<TortureContext>().create({ transformer: superjson });

const zEcho = z.object({ seed: z.string() });

function buildOutput(seed: string): TortureOutput {
  return {
    category: {
      id: seed,
      name: 'root',
      children: [
        { id: `${seed}-child`, name: 'child', children: [] },
      ],
    },
    postsByTag: { dart: [{ id: 'p1', title: 'Typed RPC', score: 9.5 }] },
    tagCounts: { asc: 3, desc: 1 },
    origin: ['root', 1.5],
    uniqueTags: new Set(['a', 'b']),
    attributes: new Map<string, number>([['weight', 2.5]]),
    version: 2,
    ownerId: 'u1' as TortureOutput['ownerId'],
    sort: 'asc',
  };
}

export const tortureRouter = t.router({
  roundTrip: t.procedure.input(TortureInputSchema).query(({ input }) => {
    return buildOutput(input.category.id);
  }),
  echo: t.procedure.input(zEcho).query(({ input }) => ({ seed: input.seed })),
});

export const appRouter = t.router({ widgets: tortureRouter });

export type AppRouter = typeof appRouter;
