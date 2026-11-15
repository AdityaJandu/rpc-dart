# Links and auth

The `RpcLink` pipeline: composable client middleware, credentials with single-flight refresh, retry safety, logging with redaction, cancellation and timeouts.

← Previous: Type mapping | Next: Vanilla Flutter →

## Pipeline

```dart
final client = RpcClient(
  endpoint: Uri.parse('https://api.example.com/trpc'),
  transformer: RpcTransformer.superjson,
  links: [
    LoggingLink(onEvent: (event) => logger.info(event)),
    AuthLink(getHeaders: () async => {'authorization': 'Bearer $token'}, onUnauthorized: refresh),
    ContextLink(dynamicHeaders: () async => {'x-app-version': appVersion}),
    RetryLink(policy: const RpcRetryPolicy(maxAttempts: 3)),
    HttpBatchLink(endpoint: Uri.parse('https://api.example.com/trpc')),
  ],
);
```

Merging precedence (lowest → highest): client `defaultHeaders` → `ContextLink` dynamic headers → `AuthLink` credentials → per-call `RpcCallContext.headers`.

## AuthLink: single-flight token refresh

When N concurrent requests receive 401, exactly **one** refresh runs; every failed request awaits the same refresh future and replays at most once with the new credentials. A second 401 after replay surfaces to the caller — no loops. A failed refresh surfaces the original unauthorized error.

```dart
AuthLink(
  getHeaders: () async => {'authorization': 'Bearer $currentToken'},
  onUnauthorized: () async {
    currentToken = await authApi.refresh();   // called exactly once per 401 wave
    return null;                              // getHeaders re-reads the new token
  },
)
```

## RetryLink: mutation safety

| Scenario | Query | Mutation |
|---|---|---|
| Network error / timeout | retry (3 attempts, exponential + cap) | **no retry** without idempotency key |
| 429 / 503 / 504 | retry honoring backoff | no retry without key |
| Permanent 4xx / decode error | never retried | never retried |

```dart
await api.posts.create.mutate(input, context: RpcCallContext(idempotencyKey: opUuid));
// with a stable key, retries become safe and are enabled automatically
```

## LoggingLink: redaction by default

Structured request/response/error events with durations. `authorization`, `cookie`, `set-cookie`, `x-api-key`, and any user-configured names are replaced with `[REDACTED]` before any sink sees them.

```dart
LoggingLink(
  onEvent: (event) => logger.info('${event.event} ${event.path} ${event.durationMs}ms'),
  redactHeaders: {'x-internal-token'},
)
```

## Cancellation and timeouts

```dart
final token = CancelToken();
final call = api.posts.list.query(input, context: RpcCallContext(
  cancelToken: token,
  timeout: const Duration(seconds: 10),
));
token.cancel(reason: 'navigated away');   // resolves with RpcCancelledException
```

Pre-dispatch cancellation removes the operation from its batch without touching siblings; mid-flight cancellation resolves that caller immediately while siblings complete. Timeouts race the transport and surface as `RpcTimeoutException`.

## Error hierarchy

Every wire error decodes through `RpcException.fromWire` into typed subtypes: `RpcBadRequestException` (carries `fieldErrors` from server-side zod data), `RpcUnauthorizedException`, `RpcNotFoundException`, `RpcTooManyRequestsException`, `RpcInternalServerException`, transport-level `RpcNetworkException`, and `RpcDecodeException` (with `path`, `expected`, `actual`) for malformed payloads. See the full table in [Troubleshooting](../reference/troubleshooting.md).

← Previous: Type mapping | Next: Vanilla Flutter →
