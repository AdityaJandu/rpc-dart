import { initTRPC, TRPCError } from '@trpc/server';
import { z } from 'zod';
import superjson from 'superjson';
import {
  PostsListInputSchema,
  UpdateUserInputSchema,
  type GetUserOutput,
  type PostOutput,
  type PostsListOutput,
} from './schemas.js';

export interface FixtureContext {
  user: { id: string } | null;
}

export type FixtureMeta = { access: 'public' | 'authenticated' };

const t = initTRPC
  .context<FixtureContext>()
  .meta<FixtureMeta>()
  .create({ transformer: superjson });

const publicProcedure = t.procedure.meta({ access: 'public' });

const protectedProcedure = t.procedure
  .use((opts) => {
    if (opts.meta?.access === 'authenticated' && !opts.ctx.user) {
      throw new TRPCError({ code: 'UNAUTHORIZED' });
    }
    return opts.next();
  })
  .meta({ access: 'authenticated' });

const zGetById = z.object({ id: z.string() });

const fixtureUser: GetUserOutput = {
  id: 'u1',
  createdAt: new Date('2026-01-15T10:00:00.000Z'),
  balance: 123n,
  payment: { type: 'card', last4: '4242' },
  sortHint: 'asc',
  metadata: { env: 'test', retries: 3 },
  nickname: null,
  address: { city: 'Delft' },
};

const fixturePosts: PostOutput[] = [
  { id: 'p1', title: 'Hello Dart', authorId: 'u1', published: true },
  { id: 'p2', title: 'Typed RPC', authorId: 'u1', published: false },
];

function userById(id: string): GetUserOutput {
  if (id !== 'u1') {
    throw new TRPCError({ code: 'NOT_FOUND' });
  }
  return fixtureUser;
}

function postsList(input: { cursor?: string }): PostsListOutput {
  const items = input.cursor === undefined ? fixturePosts : fixturePosts.slice(1);
  return { items, nextCursor: null };
}

export const userRouter = t.router({
  me: publicProcedure.query(() => fixtureUser),
  getById: protectedProcedure
    .input(zGetById)
    .query(({ input }) => userById(input.id)),
  update: protectedProcedure.input(UpdateUserInputSchema).mutation(() => fixtureUser),
});

export const postsRouter = t.router({
  list: publicProcedure.input(PostsListInputSchema).query(({ input }) => postsList(input)),
});

export const appRouter = t.router({
  user: userRouter,
  posts: postsRouter,
});

export type AppRouter = typeof appRouter;

export function createFixtureContext(authorization: string | undefined): FixtureContext {
  return {
    user: authorization === 'Bearer u1' ? { id: 'u1' } : null,
  };
}
