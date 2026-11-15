# Dart runtime API

The complete public API of `trpc_dart` (pure Dart) and `trpc_flutter` (ValueListenable bridge).

← Previous: CLI reference | Next: Troubleshooting →

## RpcClient

```dart
final client = RpcClient(
  endpoint: Uri.parse('https://api.example.com/trpc'),
  transformer: RpcTransformer.superjson,   // must match the server
  defaultHeaders: const {'x-app': 'my-app'},
  links: [AuthLink(...), HttpBatchLink(...)],
);
```

- `execute(RpcRequest) → Future<Object?>` — the only transport API generated code calls.
- `cache` — the built-in `RpcQueryCache`.
- Immutable and safe to share globally.

## Direct calls (generated procedures)

| Method | Signature | Failure mode |
|---|---|---|
| `query(input, {context})` | `Future<TOut>` | throws typed `RpcException` |
| `mutate(input, {context})` | `Future<TOut>` | throws typed `RpcException` |
| `safeQuery(input, {context})` | `Future<RpcResult<TOut>>` | never throws |
| `safeMutate(input, {context})` | `Future<RpcResult<TOut>>` | never throws |
| `watch(input, {context})` | `RpcQueryRef<TOut>` | cache-backed stream |
| `queryKey(input)` / `pathKey` | `RpcQueryKey` | structural key |

## RpcCallContext

Per-call metadata: `headers` (per-call wins over client defaults), `timeout`, `cancelToken`, `idempotencyKey` (enables safe mutation retries), `retryable`.

## RpcOpt<T>

Three-state optionality for fields that are both optional and nullable:

```dart
RpcPresent<T>(value)   // key present with a value
RpcNull<T>()           // key present with null
RpcAbsent<T>()         // key omitted from JSON
```

`RpcOpt.decode(json, key, decode: ..., model: ...)` reads it back; generated models expose `nicknameOrNull` accessors.

## RpcResult<T>

```dart
sealed class RpcResult<T> {}
final class RpcSuccess<T> extends RpcResult<T> { final T data; }
final class RpcFailure<T> extends RpcResult<T> { final RpcException error; }
```

Exhaustive via `switch`; `safeQuery`/`safeMutate` return it and never throw.

## RpcQueryCache & keys

```dart
api.cache.watch<T>(key, fetch)      // → RpcQueryRef<T>
api.invalidate(key)                  // prefix-matched refetch + invalidation stream
api.onInvalidate([prefix])           // Stream<RpcQueryKey>
api.cache.setQueryData(key, model)   // optimistic cache write
```

`RpcQueryRef<T>`: `stream` (replays current state to new listeners), `state`, `refetch()`.

`RpcQueryKey(path: ['user', 'getById'], input: model)` — deep structural equality; `matchesPrefix` is segment-based. Generated models implement deep value equality, so key equality is deep by construction.

## RpcJson

Zero-cast decoding used by generated `fromJson` and available to you:

```dart
RpcJson.asString(v, path)          // String, else RpcDecodeException(path, expected, actual)
RpcJson.asDouble(v, path)          // double; coerces JSON int 10 → 10.0
RpcJson.asDateTime(v, path)        // DateTime (decoded or ISO string)
RpcJson.asList(v, itemDecode, path)
RpcJson.asTypedMap(v, keyDecode, valDecode, path)
RpcJson.requiredField(json, 'id', RpcJson.asString, model: 'UserGetByIdOutput')
RpcJson.optionalField(json, 'cursor', RpcJson.asString, model: 'PostsListInput')
```

All failures throw `RpcDecodeException` with the breadcrumb path (`UserGetByIdOutput.items[0].title`), expected and actual types.

## Links

| Link | Purpose |
|---|---|
| `AuthLink` | dynamic credentials + single-flight 401 refresh (`getHeaders`, `onUnauthorized`, `overrideExisting`) |
| `ContextLink` | dynamic headers + `x-request-id` correlation |
| `RetryLink` | policy-driven retries with mutation idempotency guard |
| `LoggingLink` | structured events with automatic `[REDACTED]` of secret headers |
| `TransformLink` | SuperJSON encode/decode (auto-inserted) |
| `HttpBatchLink` | terminal transport: batching, splitting, demux, cancellation |

Custom links implement `RpcLink.invoke(request, next)`.

## Exceptions

`RpcException` base with `code`, `message`, `path`, `data`, `cause`; typed subtypes per wire code (`RpcUnauthorizedException`, `RpcBadRequestException` with `fieldErrors`, …). `RpcDecodeException` adds `path`/`expected`/`actual`. `RpcResult` never throws; `RpcAsyncState` is `Loading`/`Error`/`Data`.

## trpc_flutter

```dart
api.user.getById.listenable(input)   // ValueListenable<RpcAsyncState<T>> over the cache
```

Use with `ValueListenableBuilder`; updates on data, error, loading, invalidation refetches, and explicit cache writes.

← Previous: CLI reference | Next: Troubleshooting →
