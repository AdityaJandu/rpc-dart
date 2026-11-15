// NodeNext-resolution fixture: extensionless relative imports are illegal here
// (TS5097), so the extraction harness must emit an explicit specifier when it
// imports the entry. Mirrors real-world Node servers using `module: NodeNext`.
import { initTRPC } from '@trpc/server';
import { z } from 'zod';

export interface NodeNextContext {
  user: { id: string } | null;
}

const t = initTRPC.context<NodeNextContext>().create();

export const appRouter = t.router({
  health: t.procedure.query(() => ({ ok: true })),
  greet: t.procedure
    .input(z.object({ name: z.string() }))
    .query(({ input }) => ({ message: `hello ${input.name}` })),
});

export type AppRouter = typeof appRouter;
