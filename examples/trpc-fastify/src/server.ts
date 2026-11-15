
import fastify from 'fastify';
import { initTRPC, TRPCError } from '@trpc/server';
import { fastifyTRPCPlugin } from '@trpc/server/adapters/fastify';
import { z } from 'zod';
import superjson from 'superjson';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

import {
  ListPostsInputSchema,
  UpdateUserInputSchema,
  type Post,
  type User,
} from './schemas.ts';

// -----------------------------------------------------------------------------
// Configuration
// -----------------------------------------------------------------------------

const PORT = Number(process.env.PORT ?? 8787);
const HOST = process.env.HOST?.trim() || '127.0.0.1';
const TRPC_PREFIX = '/trpc';

if (
  !Number.isInteger(PORT) ||
  PORT < 0 ||
  PORT > 65535
) {
  throw new Error(`Invalid PORT: ${process.env.PORT}`);
}

// -----------------------------------------------------------------------------
// Context
// -----------------------------------------------------------------------------

export interface ExampleContext {
  user: { id: string } | null;
}

interface FastifyRequestLike {
  headers: Record<string, string | string[] | undefined>;
}

export function createContext(
  authorization: string | undefined,
): ExampleContext {
  return {
    user:
      authorization === 'Bearer demo-token'
        ? { id: 'u1' }
        : null,
  };
}

// -----------------------------------------------------------------------------
// tRPC initialization
// -----------------------------------------------------------------------------

const t = initTRPC
  .context<ExampleContext>()
  .create({
    transformer: superjson,
  });

const publicProcedure = t.procedure;

const protectedProcedure = t.procedure.use(
  ({ ctx, next }) => {
    if (!ctx.user) {
      throw new TRPCError({
        code: 'UNAUTHORIZED',
        message: 'Authentication required',
      });
    }

    return next();
  },
);

// -----------------------------------------------------------------------------
// Schemas
// -----------------------------------------------------------------------------

const GetByIdInputSchema = z.object({
  id: z.string(),
});

// -----------------------------------------------------------------------------
// Fixtures
// -----------------------------------------------------------------------------

const fixtureUser: User = {
  id: 'u1',
  name: 'Aditya',
  nickname: null,
  createdAt: new Date('2026-01-15T10:00:00.000Z'),
  balance: 4200n,
  receipt: {
    kind: 'card',
    last4: '4242',
    authorizedAt: new Date('2026-01-15T10:00:00.000Z'),
  },
};

const fixturePosts: Post[] = [
  {
    id: 'p1',
    title: 'Generated bindings',
    score: 9.5,
  },
  {
    id: 'p2',
    title: 'Zero build_runner',
    score: 8.1,
  },
  {
    id: 'p3',
    title: 'Typed end to end',
    score: 7.7,
  },
];

// -----------------------------------------------------------------------------
// Business logic
// -----------------------------------------------------------------------------

function userById(id: string): User {
  if (id !== 'u1') {
    throw new TRPCError({
      code: 'NOT_FOUND',
      message: `User ${id} not found`,
    });
  }

  return fixtureUser;
}

function listPosts(input: {
  sort: string;
  cursor?: string;
}): {
  items: Post[];
  nextCursor: string | null;
} {
  const sorted = [...fixturePosts].sort((a, b) =>
    input.sort === 'desc'
      ? b.score - a.score
      : a.score - b.score,
  );

  const pageSize = 2;

  const cursorIndex =
    input.cursor === undefined
      ? -1
      : sorted.findIndex((post) => post.id === input.cursor);

  const start = input.cursor === undefined
    ? 0
    : cursorIndex + 1;

  const items = sorted.slice(start, start + pageSize);

  const nextCursor =
    start + pageSize < sorted.length
      ? items[items.length - 1]?.id ?? null
      : null;

  return {
    items,
    nextCursor,
  };
}

// -----------------------------------------------------------------------------
// Routers
// -----------------------------------------------------------------------------

export const userRouter = t.router({
  me: protectedProcedure.query(() => {
    return fixtureUser;
  }),

  getById: publicProcedure
    .input(GetByIdInputSchema)
    .query(({ input }) => {
      return userById(input.id);
    }),

  update: protectedProcedure
    .input(UpdateUserInputSchema)
    .mutation(({ input }) => {
      // tRPC passes the parsed Zod output to the resolver.
      // The client-facing wire input can differ when schemas transform data.

      const updatedUser: User = {
        ...fixtureUser,
        name: input.name ?? fixtureUser.name,
        nickname: input.nickname ?? null,
      };

      return updatedUser;
    }),
});

export const postsRouter = t.router({
  list: publicProcedure
    .input(ListPostsInputSchema)
    .query(({ input }) => {
      return listPosts(input);
    }),
});

export const appRouter = t.router({
  health: publicProcedure.query(() => ({
    ok: true,
  })),

  user: userRouter,
  posts: postsRouter,
});

export type AppRouter = typeof appRouter;

// -----------------------------------------------------------------------------
// Fastify server
// -----------------------------------------------------------------------------

export async function startExampleServer(): Promise<{
  port: number;
  url: string;
  close: () => Promise<void>;
}> {
  const app = fastify({
    logger: false,

    // Fastify 5: router-specific options belong here,
    // rather than directly on the Fastify configuration.
    routerOptions: {
      maxParamLength: 5000,
    },
  });

  await app.register(fastifyTRPCPlugin, {
    prefix: TRPC_PREFIX,

    trpcOptions: {
      router: appRouter,

      createContext: ({
        req,
      }: {
        req: FastifyRequestLike;
      }) => {
        const authorization = req.headers.authorization;

        return createContext(
          Array.isArray(authorization)
            ? authorization[0]
            : authorization,
        );
      },
    },
  });

  try {
    await app.listen({
      port: PORT,
      host: HOST,
    });

    const address = app.server.address();

    if (!address || typeof address === 'string') {
      throw new Error('Unable to determine Fastify server address');
    }

    const actualPort = address.port;

    return {
      port: actualPort,
      url: `http://127.0.0.1:${actualPort}${TRPC_PREFIX}`,
      close: () => app.close(),
    };
  } catch (error) {
    await app.close().catch(() => {});
    throw error;
  }
}

// -----------------------------------------------------------------------------
// Standalone development entrypoint
// -----------------------------------------------------------------------------

const entrypoint = process.argv[1];

const isDirectExecution =
  entrypoint !== undefined &&
  import.meta.url === pathToFileURL(resolve(entrypoint)).href;

if (isDirectExecution) {
  void startExampleServer()
    .then((server) => {
      console.log('');
      console.log('🚀 rpc-dart Fastify example server');
      console.log('');
      console.log(`   Local:  ${server.url}`);
      console.log(`   Port:   ${server.port}`);
      console.log('');
      console.log('   Available procedures:');
      console.log('   - health');
      console.log('   - user.me             (protected)');
      console.log('   - user.getById        (public)');
      console.log('   - user.update         (protected)');
      console.log('   - posts.list          (public)');
      console.log('');
    })
    .catch((error: unknown) => {
      console.error('Failed to start example server:', error);
      process.exitCode = 1;
    });
}
