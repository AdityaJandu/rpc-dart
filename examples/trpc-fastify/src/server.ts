import fastify from 'fastify';
import { initTRPC, TRPCError } from '@trpc/server';
import { fastifyTRPCPlugin } from '@trpc/server/adapters/fastify';
import { z } from 'zod';
import superjson from 'superjson';
import {
  ListPostsInputSchema,
  UpdateUserInputSchema,
  UserSchema,
  type Post,
  type User,
} from './schemas.js';

export interface ExampleContext {
  user: { id: string } | null;
}

interface FastifyRequestLike {
  headers: Record<string, string | string[] | undefined>;
}

export function createContext(authorization: string | undefined): ExampleContext {
  return { user: authorization === 'Bearer demo-token' ? { id: 'u1' } : null };
}

const t = initTRPC.context<ExampleContext>().create({ transformer: superjson });

const publicProcedure = t.procedure;
const protectedProcedure = t.procedure.use((opts) => {
  if (!opts.ctx.user) {
    throw new TRPCError({ code: 'UNAUTHORIZED' });
  }
  return opts.next();
});

const zGetById = z.object({ id: z.string() });

const fixtureUser: User = {
  id: 'u1',
  name: 'Aditya',
  nickname: null,
  createdAt: new Date('2026-01-15T10:00:00.000Z'),
  balance: 4200n,
  receipt: { kind: 'card', last4: '4242', authorizedAt: new Date('2026-01-15T10:00:00.000Z') },
};

const fixturePosts: Post[] = [
  { id: 'p1', title: 'Generated bindings', score: 9.5 },
  { id: 'p2', title: 'Zero build_runner', score: 8.1 },
  { id: 'p3', title: 'Typed end to end', score: 7.7 },
];

function userById(id: string): User {
  if (id !== 'u1') {
    throw new TRPCError({ code: 'NOT_FOUND' });
  }
  return fixtureUser;
}

function listPosts(input: { sort: string; cursor?: string }): { items: Post[]; nextCursor: string | null } {
  const sorted = [...fixturePosts].sort((a, b) =>
    input.sort === 'desc' ? b.score - a.score : a.score - b.score,
  );
  const pageSize = 2;
  const start = input.cursor === undefined ? 0 : sorted.findIndex((p) => p.id === input.cursor) + 1;
  const items = sorted.slice(start, start + pageSize);
  const nextCursor = start + pageSize < sorted.length ? (items[items.length - 1]?.id ?? null) : null;
  return { items, nextCursor };
}

export const userRouter = t.router({
  me: protectedProcedure.query(() => fixtureUser),
  getById: publicProcedure.input(zGetById).query(({ input }) => userById(input.id)),
  update: protectedProcedure.input(UpdateUserInputSchema).mutation(({ input }) => {
    // input is the wire shape (z.input): promoCode is a raw string here even
    // though the resolver receives the transformed uppercase version.
    return { ...fixtureUser, name: input.name ?? fixtureUser.name, nickname: input.nickname ?? null } as User;
  }),
});

export const postsRouter = t.router({
  list: publicProcedure.input(ListPostsInputSchema).query(({ input }) => listPosts(input)),
});

export const appRouter = t.router({
  health: publicProcedure.query(() => ({ ok: true })),
  user: userRouter,
  posts: postsRouter,
});

export type AppRouter = typeof appRouter;

export async function startExampleServer(): Promise<{ port: number; close: () => Promise<void> }> {
  const app = fastify({ logger: false, maxParamLength: 5000 });
  await app.register(fastifyTRPCPlugin, {
    prefix: '/trpc',
    trpcOptions: {
      router: appRouter,
      createContext: ({ req }: { req: FastifyRequestLike }) =>
        createContext(
          Array.isArray(req.headers.authorization) ? req.headers.authorization[0] : req.headers.authorization,
        ),
    },
  });
  await app.listen({ port: 0, host: '127.0.0.1' });
  const address = app.server.address();
  const port = typeof address === 'object' && address !== null ? address.port : 0;
  return { port, close: () => app.close() };
}

// Standalone dev entrypoint: `npm run dev`
if (process.argv[1]?.endsWith('server.ts')) {
  void startExampleServer().then((server) => {
    console.log(`example server listening on http://127.0.0.1:${server.port}/trpc`);
  });
}

void z;
void UserSchema;
