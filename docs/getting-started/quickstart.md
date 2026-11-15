# Quickstart

A 5-minute end-to-end tutorial: Fastify + tRPC v11 backend → generated Dart bindings → Flutter app.

← Previous: Installation | Next: How it works →

## 1. Backend router (Fastify + tRPC v11 + Zod)

```typescript
// src/trpc/router.ts
import { initTRPC, TRPCError } from '@trpc/server';
import { z } from 'zod';
import superjson from 'superjson';

const t = initTRPC.create({ transformer: superjson });

const posts = [
  { id: 'p1', title: 'Generated bindings', score: 9.5 },
  { id: 'p2', title: 'Zero build_runner', score: 8.1 },
];

export const userRouter = t.router({
  me: t.procedure.query(() => ({ id: 'u1', name: 'Aditya', createdAt: new Date() })),
  getById: t.procedure.input(z.object({ id: z.string() })).query(({ input }) => ({
    id: input.id,
    name: 'Aditya',
    createdAt: new Date(),
  })),
  update: t.procedure
    .input(z.object({
      name: z.string().optional(),
      nickname: z.string().optional().nullable(),   // PATCH: absent vs null vs value
    }))
    .mutation(({ input }) => ({ id: 'u1', ...input })),
});

export const appRouter = t.router({
  health: t.procedure.query(() => ({ ok: true })),
  user: userRouter,
  posts: t.router({
    list: t.procedure.input(z.object({ sort: z.enum(['asc', 'desc']) })).query(() => ({
      items: posts,
      nextCursor: null,
    })),
  }),
});

export type AppRouter = typeof appRouter;
```

Mount it with the Fastify adapter and start `npx rpc-dart watch` next to your dev server.

## 2. Generate the Dart bindings

```bash
npx rpc-dart generate --tsconfig tsconfig.json --entry src/trpc/router.ts \
  --export appRouter --out ../mobile/lib/src/api
```

This writes `lib/src/api/` into your Flutter app: `api.dart`, router classes, procedure classes, and model files. Commit them — there is no Dart-side build step.

## 3. Flutter: configure the client

```dart
import 'package:trpc_dart/trpc_dart.dart';
import 'src/api/api.dart';

final client = RpcClient(
  endpoint: Uri.parse('http://10.0.2.2:3000/trpc'),   // Android emulator loopback
  transformer: RpcTransformer.superjson,               // match the server
  links: [
    AuthLink(getHeaders: () async => {'authorization': 'Bearer $token'}),
    RetryLink(policy: RpcRetryPolicy(maxAttempts: 3)),
    HttpBatchLink(endpoint: Uri.parse('http://10.0.2.2:3000/trpc')),
  ],
);

final api = Api(client);
```

## 4. Make typed calls

```dart
// Direct, fully typed calls — no route strings.
final user = await api.user.getById.query(const UserGetByIdInput(id: 'u1'));

// Result-typed variant (never throws).
final res = await api.user.update.safeMutate(
  UserUpdateInput(name: RpcPresent('Ada'), nickname: const RpcNull()),
);
switch (res) {
  case RpcSuccess(:final data):
    print('updated ${data.id}');
  case RpcFailure(:final error):
    print('failed: ${error.message}');
}

// Reactive state through the built-in cache.
ValueListenableBuilder<RpcAsyncState<UserGetByIdOutput>>(
  valueListenable: api.user.getById.listenable(const UserGetByIdInput(id: 'u1')),
  builder: (context, state, _) => switch (state) {
    RpcAsyncLoading() => const CircularProgressIndicator(),
    RpcAsyncError(:final error) => Text('error: $error'),
    RpcAsyncData(:final data) => Text(data.name),
  },
);

// Explicit invalidation after mutations.
api.invalidate(api.user.pathKey);
```

## 5. Compile-time safety in action

Rename `user.getById` to `user.fetchById` on the server, re-run `rpc-dart generate`, and run `flutter analyze`: every stale call site now fails with `The getter 'getById' isn't defined` — before the app ever ships.

← Previous: Installation | Next: How it works →
