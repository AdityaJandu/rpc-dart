import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:trpc_dart/trpc_dart.dart';

/// Bridges a cache-backed query ref to Flutter's native [ValueListenable].
/// The listenable updates on data, error, loading, invalidation-triggered
/// refetches, and explicit cache writes.
extension RpcQueryRefFlutter<T> on RpcQueryRef<T> {
  ValueListenable<RpcAsyncState<T>> get listenable => _RpcQueryListenable<T>(this);
}

/// `api.user.getById.listenable(input)` ergonomics for generated procedures.
extension RpcWatchableFlutter<TInput, TOutput> on RpcWatchable<TInput, TOutput> {
  ValueListenable<RpcAsyncState<TOutput>> listenable(
    TInput input, {
    RpcCallContext? context,
  }) {
    return watch(input, context: context).listenable;
  }
}

/// No-input ergonomics: `api.user.me.listenable()`.
extension RpcWatchableNoInputFlutter<TOutput> on RpcWatchableNoInput<TOutput> {
  ValueListenable<RpcAsyncState<TOutput>> listenable({RpcCallContext? context}) {
    return watch(context: context).listenable;
  }
}

final class _RpcQueryListenable<T> extends ValueNotifier<RpcAsyncState<T>> {
  _RpcQueryListenable(RpcQueryRef<T> ref) : super(ref.state) {
    _subscription = ref.stream.listen((state) {
      value = state;
    });
  }

  late final StreamSubscription<RpcAsyncState<T>> _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
