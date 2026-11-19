# Changelog

## 0.3.0

- Synchronized v0.3.0 lockstep release with `trpc_dart` 0.3.0 (oRPC transport, binary/multipart transfers, progress callbacks). No API changes in the Flutter bridge itself.


## 0.2.0

- `RpcSubscriptionController<T>` + `RpcSubscriptionState<T>`: bind subscription streams to a `ValueListenable` with bounded history, status lifecycle, tracked-event id resume, and automatic query-cache prefix invalidation on incoming events.
- `streamFactory` now receives an `onReconnect` hook to forward into `RpcSubscriptionOptions.onReconnect`; the controller transitions `connecting -> active -> reconnecting -> active`, preserving the last `data`, `history`, and `lastEventId` across a drop/reconnect cycle.
- `trpc_dart` constraint raised to `^0.2.0`.

## 0.1.4

- Synchronized v0.1.4 lockstep release; `trpc_dart` constraint raised to `^0.1.4`.

## 0.1.3

- Comprehensive package documentation and runnable ValueListenable examples for pub.dev.
- 100% public API dartdoc coverage and full Dart 3.10 formatting compliance.
- Fixed repository provenance verification in pubspec.yaml with clean pubspec_overrides architecture.

## 0.1.2

- Idempotent OIDC release pipeline and lockstep v0.1.2 package release.

## 0.1.1

- Align repository metadata and packaging rules for automated OIDC publishing.

## 0.1.0

- Initial release.
