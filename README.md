# rpc-dart

End-to-end type safety for tRPC v11 and oRPC backends consumed from Dart and Flutter. The `rpc-dart` CLI reads your TypeScript router and generates plain, build-tool-free Dart bindings; the `trpc_dart` runtime calls your server over the real tRPC and oRPC wire protocols with a composable link pipeline and a built-in, state-management-agnostic query cache.

Rename a procedure or change a Zod field on the server: the Dart bindings regenerate in milliseconds and the Dart analyzer breaks at every stale call site. No route strings, no hand-written models, no `build_runner`, no `freezed`.

```
TypeScript router ──► rpc-dart CLI ──► generated Dart bindings ──► trpc_dart runtime ──► your tRPC server
```

## Core Features

- **Zero manual route strings.** Nested routers compile to nested typed getters: `api.user.getById.query(...)`.
- **Compile-time safety across languages.** Renaming a procedure or changing a Zod input field triggers a Dart analyzer error at every affected call site after regeneration.
- **No Dart build step.** Generated code is plain Dart 3: const constructors, `copyWith`, value equality, `fromJson`/`toJson`. AOT-compatible. `build_runner`, `freezed`, and `json_serializable` are never required.
- **Input vs output correctness.** Zod `.transform()`, `.default()`, and `.coerce()` are handled correctly: wire input models come from `z.input`, response models from `z.output`.
- **Three-state PATCH semantics.** `RpcOpt<T>` distinguishes an omitted key, an explicit `null`, and a value — no silent merge bugs on partial updates.
- **Unknown-safe enums and unions.** Server-side enum additions decode to `$unknown` sentinels instead of crashing the app; discriminated unions become sealed Dart classes.
- **State-management agnostic.** Direct calls (`.query()`, `.mutate()`, `.safeQuery()`, `.safeMutate()`), structural query keys, a zero-dependency `RpcQueryCache` with invalidation streams and `.watch()`, and a native Flutter `ValueListenable` bridge. Works with `setState`, BLoC, Provider, Riverpod, or nothing at all.
- **Real-time subscriptions.** Generated `.subscribe()` streams over SSE or WebSocket with `tracked()` resume, exponential-backoff reconnect, and single-flight auth refresh (`HttpSubscriptionLink`, `WsSubscriptionLink`, `SplitLink`).
- **Composable middleware.** A link pipeline (`AuthLink`, `RetryLink`, `HttpBatchLink`, ...) with per-call context: headers, timeouts, cancellation, idempotency keys.
- **Real protocol support.** HTTP batching with index-correlated responses, SuperJSON envelopes (`Date`, `BigInt`, `NaN`, ...), SSE subscriptions, the full tRPC error-code table as typed exceptions.
- **oRPC support.** The `@rpc-dart/orpc-adapter` extracts `oc` contracts and `os` / `implement()` routers (Standard Schema v1: Zod, Valibot, ArkType), including handler-inferred outputs, `eventIterator` subscriptions, and `.errors()` typed error maps. `OrpcLink` speaks the RPCHandler wire: `{json, meta}` envelopes, multipart file maps, and SSE event iterators.
- **Binary & file transfers.** `RpcFile`, `Uint8List`, and `RpcByteStream` flow end-to-end with `onSendProgress` / `onReceiveProgress` callbacks, cancellation, and zero casts — native multipart on oRPC, a SuperJSON `registerCustom` convention on tRPC.

## Quickstart

### 1. Backend: install the CLI

Requires Node.js 20+ and a tRPC v11 router or an oRPC contract/router (with or
without Zod — oRPC accepts any Standard Schema v1 library: Zod, Valibot, ArkType).

```bash
npm install --save-dev rpc-dart     # or: pnpm add -D rpc-dart
npx rpc-dart init                   # detects your router, tsconfig, and Flutter target; scaffolds rpc-dart.config.ts
npx rpc-dart watch                  # run next to your dev server; regenerates Dart on router changes
```

A minimal `rpc-dart.config.ts`:

```typescript
import { defineConfig } from 'rpc-dart';

export default defineConfig({
  entry: './src/trpc/router.ts',      // module that exports the router
  exportName: 'appRouter',
  transformer: 'superjson',           // must match your initTRPC transformer
  dart: { outDir: '../mobile/lib/src/api' },
});
```

Make sure the router type is exported next to the router itself:

```typescript
const appRouter = t.router({ user: userRouter, posts: postsRouter });
export type AppRouter = typeof appRouter;
export { appRouter };
```

### 2. Flutter: add the runtime

```yaml
dependencies:
  # tRPC backends:
  trpc_dart: ^0.3.0          # pure Dart runtime (works on server, CLI, web, VM)
  trpc_flutter: ^0.3.0       # optional: ValueListenable bridge for Flutter UIs
  # oRPC backends — install the orpc_* facades instead:
  orpc_dart: ^0.3.0          # oRPC runtime facade over trpc_dart (hides tRPC-only transports)
  orpc_flutter: ^0.3.0       # optional: orpc_dart + the Flutter ValueListenable bridge
```

oRPC clients install the `orpc_*` facades and import
`package:orpc_dart/orpc_dart.dart`; the tRPC example below uses `trpc_dart`.

```dart
import 'package:trpc_dart/trpc_dart.dart';
import 'api/api.dart';                    // generated

final endpoint = Uri.parse('https://api.example.com/trpc');
final client = RpcClient(
  endpoint: endpoint,
  transformer: RpcTransformer.superjson,  // match the server transformer
  links: [
    AuthLink(getHeaders: () async => {'authorization': 'Bearer $token'}),
    HttpBatchLink(endpoint: endpoint),
  ],
);

final api = Api(client);                  // generated root
```

## Usage Examples

Given a backend with `user.me`, `user.getById`, `user.update`, and `posts.list` procedures:

### Vanilla Flutter: setState, FutureBuilder, ValueListenableBuilder

```dart
// One-shot call with setState
Future<void> _load() async {
  setState(() => _loading = true);
  try {
    final user = await api.user.getById.query(UserGetByIdInput(id: widget.userId));
    setState(() => _user = user);
  } on RpcUnauthorizedException {
    Navigator.pushNamed(context, '/login');
  } finally {
    setState(() => _loading = false);
  }
}

// Result-typed variant (no throwing): switch over RpcResult
final res = await api.user.getById.safeQuery(UserGetByIdInput(id: widget.userId));
switch (res) {
  case RpcSuccess(:final data):
    print('hello ${data.id}');
  case RpcFailure(:final error):
    print('failed: ${error.message}');        // error carries zod field errors when present
}

// Reactive: ValueListenableBuilder over the built-in cache.
// The listenable updates itself when this query is invalidated or refetched.
ValueListenableBuilder<RpcAsyncState<UserGetByIdOutput>>(
  valueListenable: api.user.getById.listenable(UserGetByIdInput(id: widget.userId)),
  builder: (context, state, _) => switch (state) {
    RpcAsyncLoading() => const CircularProgressIndicator(),
    RpcAsyncError(:final error) => Text('error: $error'),
    RpcAsyncData(:final data) => Text(data.id),
  },
);

// Mutations refresh the cache explicitly — no string heuristics:
final updated = await api.user.update.mutate(UserUpdateInput(
  name: 'Ada',
  nickname: const RpcNull(),               // explicit null on the wire
  promoCode: 'PROMO2024',                  // required field
));
api.invalidate(api.user.pathKey);          // refetches every watched query under 'user'
```

### BLoC / Cubit

```dart
class UserCubit extends Cubit<RpcAsyncState<UserGetByIdOutput>> {
  UserCubit(this._api, this._userId)
      : super(const RpcAsyncLoading());

  final Api _api;
  final String _userId;
  StreamSubscription<RpcQueryKey>? _invalidationSub;

  void watch() {
    // .watch() yields a Stream<RpcAsyncState<T>> that re-emits on invalidation.
    _invalidationSub = _api.onInvalidate(_api.user.pathKey).listen((_) {});
    _api.user.getById
        .watch(UserGetByIdInput(id: _userId))
        .stream
        .listen(emit);
  }

  Future<void> rename(String name) async {
    await _api.user.update.mutate(UserUpdateInput(name: name, promoCode: 'PROMO2024'));
    _api.invalidate(_api.user.pathKey);   // the watched cubit state refreshes itself
  }

  @override
  void close() {
    _invalidationSub?.cancel();
    return super.close();
  }
}
```

### Provider (ChangeNotifier)

```dart
class UserNotifier extends ChangeNotifier {
  UserNotifier(this._api, this._userId) {
    _sub = _api.user.getById
        .watch(UserGetByIdInput(id: _userId))
        .stream
        .listen((state) {
      _state = state;
      notifyListeners();
    });
  }

  final Api _api;
  final String _userId;
  late final StreamSubscription<RpcAsyncState<UserGetByIdOutput>> _sub;
  RpcAsyncState<UserGetByIdOutput> _state = const RpcAsyncLoading();

  RpcAsyncState<UserGetByIdOutput> get state => _state;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
```

### Riverpod

```dart
// Family provider over the typed call — invalidation via the structural key.
final userProvider = FutureProvider.autoDispose
    .family<UserGetByIdOutput, String>((ref, id) async {
  final api = ref.watch(apiProvider);
  final invalidate = api.onInvalidate(api.user.getById.pathKey);
  ref.onDispose(invalidate.listen((_) => ref.invalidateSelf()).cancel);
  return api.user.getById.query(UserGetByIdInput(id: id));
});

// Or keep the built-in cache as the single source of truth:
final userStateProvider = StreamProvider.autoDispose
    .family<RpcAsyncState<UserGetByIdOutput>, String>((ref, id) {
  final api = ref.watch(apiProvider);
  return api.user.getById.watch(UserGetByIdInput(id: id)).stream;
});
```

## Link Pipeline

Requests flow through a composable chain. The last link is the transport.

```
Api call → LoggingLink → AuthLink → ContextLink → RetryLink → HttpBatchLink
```

| Link | Responsibility |
|---|---|
| `AuthLink` | Resolves tokens asynchronously, attaches headers, performs single-flight token refresh: 10 concurrent 401s produce exactly one refresh, then replay |
| `HttpBatchLink` | Terminal transport: coalesces same-tick calls into one HTTP request, splits oversized GET batches, demultiplexes index-correlated responses and per-item errors, and encodes/decodes the SuperJSON envelope (`Date`, `BigInt`, `NaN`, ...) via its `transformer` param (matching `RpcClient.transformer`) |
| `LoggingLink` | Structured logging with automatic redaction of `authorization`, cookies, and token-shaped payload keys |
| `RetryLink` | Policy-driven retries: queries retry on network errors with exponential backoff; mutations never retry without an explicit idempotency key |

Per-call overrides ride on `RpcCallContext` and never touch client configuration:

```dart
final user = await api.user.getById.query(
  UserGetByIdInput(id: '1'),
  context: RpcCallContext(
    headers: {'x-org-id': 'org_99'},
    timeout: Duration(seconds: 5),
    cancelToken: token,
  ),
);
```

Custom links are plain functions over the chain:

```dart
class OrgHeaderLink implements RpcLink {
  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) {
    return next(request.withAddedHeader('x-org-id', currentOrgId));
  }
}
```

## CLI Reference

| Command | What it does |
|---|---|
| `rpc-dart init` | Detects the tRPC setup, `tsconfig.json`, and Flutter target; scaffolds `rpc-dart.config.ts`; runs the environment checklist |
| `rpc-dart generate` | Extracts the router, produces the intermediate contract, and writes Dart bindings. Writes only when the contract hash changed; removes stale files via the manifest |
| `rpc-dart watch` | Incremental mode: on each TypeScript save, re-extracts, compares the contract hash, and re-emits only when it changed. Keeps the last good output while you type |
| `rpc-dart check` | CI gate: verifies committed Dart files match the current router. Exits non-zero on drift |
| `rpc-dart diff` | Compares the current contract against a baseline snapshot and categorizes breaking vs non-breaking changes (removed procedures, narrowed inputs, changed outputs) |
| `rpc-dart doctor` | Validates Node/Dart versions, `tsconfig.json`, path aliases, router export visibility, and package compatibility |
| `rpc-dart clean` | Removes exactly the files listed in the generation manifest — never globs |

## Documentation

Full website-structured documentation lives in [docs/](docs/README.md):

- [Getting started](docs/getting-started/installation.md) — installation, config, [quickstart](docs/getting-started/quickstart.md)
- [Concepts](docs/README.md#table-of-contents) — how the compiler works, type mapping, links & auth
- [Guides](docs/README.md#table-of-contents) — vanilla Flutter, BLoC, Provider, Riverpod, [oRPC quickstart](docs/guides/orpc-quickstart.md), [file & binary transfers](docs/guides/file-transfers.md), monorepo & CI
- [Reference](docs/README.md#table-of-contents) — CLI reference, Dart runtime API, troubleshooting
- [Roadmap](UPCOMING_TASKS.md) — shipped milestones and upcoming work

## License

MIT — see [LICENSE](LICENSE).
