import { initTRPC } from '@trpc/server';
import { z } from 'zod';
import superjson from 'superjson';
import {
  BrokenDumpSchema,
  BrokenJobSchema,
  type WeirdShape,
} from './schemas.js';

export interface DiagnosticsContext {
  user: { id: string } | null;
}

const t = initTRPC.context<DiagnosticsContext>().create({ transformer: superjson });

const zEmpty = z.object({ seed: z.string().optional() });

const brokenDump: z.infer<typeof BrokenDumpSchema> = {
  id: 'd1',
  callback: () => 'x',
};

const brokenJob: z.infer<typeof BrokenJobSchema> = {
  id: 'j1',
  result: Promise.resolve('r'),
};

const weirdShape: WeirdShape = { a: 'x' };

export const diagnosticsRouter = t.router({
  dump: t.procedure.input(zEmpty).query(() => brokenDump),
  job: t.procedure.input(zEmpty).query(() => brokenJob),
  weird: t.procedure.input(zEmpty).query(() => weirdShape),
  healthy: t.procedure.input(zEmpty).query(() => ({ ok: true })),
});

export const appRouter = t.router({ diagnostics: diagnosticsRouter });

export type AppRouter = typeof appRouter;
