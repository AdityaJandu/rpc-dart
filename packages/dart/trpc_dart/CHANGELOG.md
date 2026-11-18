# Changelog

## 0.2.0

- Real-time subscriptions: `HttpSubscriptionLink` (SSE, tRPC `httpSubscriptionLink`-compatible) and `WsSubscriptionLink` (multiplexed WebSocket, `applyWSSHandler`-compatible) with an injectable WebSocket connector.
- `SplitLink` routes query/mutation to the unary link and subscriptions to a stream link, with custom predicate routing.
- `RpcSubscriptionOptions` (lastEventId resume, CancelToken, headers, connectionParams, per-subscription reconnect policy, `onEventId`, `idleTimeout`, `onReconnect`) and `RpcReconnectPolicy` (exponential backoff + jitter, injectable random).
- `RpcLink.invokeStream` / `RpcClient.sendStream` / `RpcClient.subscribe<T>`: streaming pipeline with retryable-failure reconnection that re-runs the whole chain per attempt (fresh headers, single-flight auth refresh, latest tracked event id resume). Non-retryable 4xx errors terminate; `onReconnect(attempt, error)` fires before each scheduled reconnect.
- `HttpSubscriptionLink` idle/heartbeat detection: `idleTimeout` aborts and reconnects a silent (half-open) stream, resets on every frame/comment/`:ping`, and cancels cleanly on unsubscribe; the SSE `retry:` hint floors the next reconnect delay.
- `WsSubscriptionLink` unwraps `tracked()` envelopes by the authoritative `result.id`, leaving domain objects that happen to carry `{id, data}` fields intact.
- `AuthLink`, `ContextLink`, and `LoggingLink` gained streaming counterparts with the same semantics as their unary paths.
- `SseParser`: spec-compliant chunk-safe SSE frame decoder (UTF-8 mid-codepoint splits, CRLF/LF/CR lines, comments, multi-line data).
- SuperJSON encoding gains `Set` support.

## 0.1.4

- Synchronized v0.1.4 lockstep release; no runtime changes.

## 0.1.3

- Comprehensive package documentation and runnable standalone examples for pub.dev.
- Expanded public API dartdoc coverage to 83%+ and full Dart 3.10 formatting compliance.
- Fixed repository provenance verification in pubspec.yaml for 160/160 pub points.

## 0.1.2

- Idempotent OIDC release pipeline and lockstep v0.1.2 package release.

## 0.1.1

- Align repository metadata and packaging rules for automated OIDC publishing.

## 0.1.0

- Initial release.
