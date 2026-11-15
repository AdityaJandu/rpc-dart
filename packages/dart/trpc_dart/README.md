# trpc_dart

[![pub package](https://img.shields.io/pub/v/trpc_dart.svg)](https://pub.dev/packages/trpc_dart)
[![pub points](https://img.shields.io/pub/points/trpc_dart)](https://pub.dev/packages/trpc_dart/score)
[![license](https://img.shields.io/github/license/AdityaJandu/rpc-dart.svg)](https://github.com/AdityaJandu/rpc-dart/blob/main/LICENSE)
[![GitHub CI](https://github.com/AdityaJandu/rpc-dart/actions/workflows/ci.yml/badge.svg)](https://github.com/AdityaJandu/rpc-dart/actions/workflows/ci.yml)

Pure Dart runtime for [tRPC](https://trpc.io) v11 clients. Provides a composable link pipeline, automatic HTTP batching, SuperJSON decoding, typed error hierarchies, and a state-agnostic query cache.

Works anywhere Dart runs: Flutter (iOS, Android, Web, macOS, Windows, Linux), Dart CLI tools, and backend Dart servers.

Part of the [rpc-dart](https://github.com/AdityaJandu/rpc-dart) monorepo.

---

## Features

- **Composable link pipeline:** Chain middleware for authentication, retries, logging, context, and transport.
- **HTTP batching transport:** `HttpBatchLink` combines multiple procedure calls dispatched in the same event-loop tick into a single index-aligned HTTP request.
- **SuperJSON envelope support:** Decodes `Date` into `DateTime`, `bigint` into `BigInt`, `NaN`/`Infinity`, `Set`, and `Uri` without silent data loss.
- **Zero-cast JSON reader:** `RpcJson` parses JSON with Dart 3 pattern matching, attaching field breadcrumbs (`UserGetByIdOutput.receipt.authorizedAt`) to any type mismatch.
- **Three-state PATCH handling:** `RpcOpt<T>` distinguishes omitted keys, explicit `null`, and updated values.
- **Framework-free query cache:** `RpcQueryCache` manages query deduplication, invalidation streams, and optimistic updates without tying you to any state management library.
- **Typed exception table:** Exceptions map directly to the tRPC v11 error specification (`RpcBadRequestException`, `RpcUnauthorizedException`, `RpcNotFoundException`, and more).

---

## Installation

Add `trpc_dart` to your `pubspec.yaml`:

```yaml
dependencies:
  trpc_dart: ^0.1.3
```

Then run:

```bash
dart pub get
# or for Flutter:
flutter pub get
```

---

## Quickstart

Generated client code uses `RpcClient` to execute procedure calls:

```dart
import 'package:trpc_dart/trpc_dart.dart';

void main() async {
  // 1. Configure client and link chain
  final client = RpcClient(
    endpoint: Uri.parse('https://api.example.com/trpc'),
    transformer: RpcTransformer.superjson,
    links: [
      // Logs requests and responses, redacting secrets automatically
      LoggingLink(onEvent: (event) => print('[rpc] ${event.event} ${event.path}')),

      // Retries transient failures with exponential backoff
      RetryLink(policy: const RpcRetryPolicy(maxAttempts: 3)),

      // Automatically refreshes tokens on 401 UNAUTHORIZED
      AuthLink(
        getHeaders: () async => {'authorization': 'Bearer my-token'},
        onUnauthorized: () async => refreshSessionToken(),
      ),

      // Terminal transport: coalesces calls into batched HTTP requests
      HttpBatchLink(endpoint: Uri.parse('https://api.example.com/trpc')),
    ],
  );

  // 2. Execute procedure directly or through generated bindings
  try {
    final response = await client.execute(const RpcRequest(
      path: 'user.getById',
      kind: RpcProcedureKind.query,
      input: {'id': 'user-123'},
    ));
    print('Raw response: $response');
  } on RpcUnauthorizedException {
    print('Session expired');
  } on RpcBadRequestException catch (e) {
    print('Validation failed: ${e.fieldErrors}');
  } on RpcException catch (e) {
    print('RPC error (${e.code}): ${e.message}');
  }
}

Future<void> refreshSessionToken() async {
  // Fetch fresh credentials
}
```

---

## Composable Link Pipeline

Links execute in the order declared in the `links` list:

```dart
final client = RpcClient(
  endpoint: Uri.parse('https://api.example.com/trpc'),
  links: [
    // 1. Request logging with automatic redaction
    LoggingLink(
      onEvent: (e) => print('${e.event} ${e.path} (${e.durationMs}ms)'),
      redactHeaders: {'x-custom-secret'},
    ),

    // 2. Correlation IDs and dynamic application headers
    ContextLink(
      correlate: true, // generates and attaches x-request-id
      dynamicHeaders: () async => {'x-client-version': '1.0.0'},
    ),

    // 3. Authentication with single-flight refresh lock
    AuthLink(
      getHeaders: () async => {'authorization': 'Bearer $token'},
      onUnauthorized: () async => authService.refreshToken(),
    ),

    // 4. Retry link: queries retry automatically; mutations only retry if idempotent
    RetryLink(
      policy: RpcRetryPolicy(
        maxAttempts: 3,
        backoff: const Duration(milliseconds: 250),
      ),
    ),

    // 5. Terminal batch transport (exactly one termination link required)
    HttpBatchLink(
      endpoint: Uri.parse('https://api.example.com/trpc'),
      maxBatchSize: 10,
    ),
  ],
);
```

---

## Query Cache & Invalidation

`RpcQueryCache` runs independently of Flutter and state-management packages:

```dart
final cache = client.cache;

// Watch a query: returns an RpcQueryRef with a broadcast stream
final ref = cache.watch(
  const RpcQueryKey(path: ['user', 'me']),
  () => fetchCurrentUser(),
);

ref.stream.listen((state) {
  switch (state) {
    case RpcAsyncLoading():
      print('Loading user...');
    case RpcAsyncData(:final data):
      print('Loaded user: $data');
    case RpcAsyncError(:final error):
      print('Query failed: $error');
  }
});

// Invalidate specific query keys or entire subtrees:
cache.invalidate(const RpcQueryKey(path: ['user'])); // refetches all 'user.*' watchers

// Listen to invalidations:
cache.onInvalidate().listen((key) {
  print('Cache invalidated: ${key.path.join(".")}');
});

// Optimistic update:
cache.setQueryData(
  const RpcQueryKey(path: ['user', 'me']),
  updatedUser,
);
```

---

## Zero-Cast Deserialization (`RpcJson`)

`RpcJson` eliminates uncaught `TypeError` crashes when server contracts change:

```dart
// Type-safe extraction with breadcrumb paths:
final name = RpcJson.asString(data['name'], 'User.name');
final count = RpcJson.asInt(data['count'], 'User.count');
final date = RpcJson.asDateTime(data['createdAt'], 'User.createdAt');
final items = RpcJson.asList(data['items'], (item, path) => Item.fromJson(item as Map<String, Object?>));
```

If the server sends a number instead of a string, `RpcJson` throws `RpcDecodeException`:
`RpcDecodeException(DECODE) at User.name (expected String, got int): expected String but received int`

---

## Links

- [Documentation](https://github.com/AdityaJandu/rpc-dart/blob/main/docs/README.md)
- [CLI Generator (rpc-dart)](https://www.npmjs.com/package/rpc-dart)
- [Flutter Bridge (trpc_flutter)](https://pub.dev/packages/trpc_flutter)
- [GitHub Repository](https://github.com/AdityaJandu/rpc-dart)
- [Issue Tracker](https://github.com/AdityaJandu/rpc-dart/issues)

---

## License

MIT © [Aditya Jandu](https://github.com/AdityaJandu)
