/// Flutter integration for oRPC clients: a [ValueListenable] bridge over
/// cache-backed queries for [ValueListenableBuilder], Riverpod, BLoC, and
/// Provider, plus [RpcSubscriptionController] for real-time event iterators.
///
/// Thin facade combining the [`orpc_dart`](https://pub.dev/packages/orpc_dart)
/// runtime with the protocol-agnostic Flutter bridge from
/// [`trpc_flutter`](https://pub.dev/packages/trpc_flutter). tRPC-only
/// transports are not re-exported.
library;

export 'package:orpc_dart/orpc_dart.dart';
export 'package:trpc_flutter/trpc_flutter.dart';
