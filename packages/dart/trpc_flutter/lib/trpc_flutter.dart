/// Flutter integration for trpc_dart: provides a [ValueListenable] bridge
/// over cache-backed queries for [ValueListenableBuilder], Riverpod, BLoC, and Provider.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:trpc_dart/trpc_dart.dart';

/// Bridges a cache-backed query ref to Flutter's native [ValueListenable].
/// The listenable updates on data, error, loading, invalidation-triggered
/// refetches, and explicit cache writes.
extension RpcQueryRefFlutter<T> on RpcQueryRef<T> {
  /// Returns a [ValueListenable] that emits updates whenever this query ref transitions
  /// between loading, data, or error states.
  ValueListenable<RpcAsyncState<T>> get listenable =>
      _RpcQueryListenable<T>(this);
}

/// `api.user.getById.listenable(input)` ergonomics for generated procedures.
extension RpcWatchableFlutter<TInput, TOutput>
    on RpcWatchable<TInput, TOutput> {
  /// Watches the procedure with [input] and returns a [ValueListenable]
  /// tracking its [RpcAsyncState].
  ValueListenable<RpcAsyncState<TOutput>> listenable(
    TInput input, {
    RpcCallContext? context,
  }) {
    return watch(input, context: context).listenable;
  }
}

/// No-input ergonomics: `api.user.me.listenable()`.
extension RpcWatchableNoInputFlutter<TOutput> on RpcWatchableNoInput<TOutput> {
  /// Watches the procedure without input and returns a [ValueListenable]
  /// tracking its [RpcAsyncState].
  ValueListenable<RpcAsyncState<TOutput>> listenable(
      {RpcCallContext? context}) {
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

/// Lifecycle of a real-time subscription UI binding.
enum RpcSubscriptionStatus {
  /// Created but not started.
  idle,

  /// Opening the stream.
  connecting,

  /// Events are flowing.
  active,

  /// Re-established after a drop (reconnect runs inside the link chain).
  reconnecting,

  /// The server completed the stream normally.
  done,

  /// The stream failed; [RpcSubscriptionState.error] carries the reason.
  error,
}

/// Immutable snapshot of a subscription's UI-facing state.
class RpcSubscriptionState<T> {
  const RpcSubscriptionState({
    this.status = RpcSubscriptionStatus.idle,
    this.data,
    this.history = const <Never>[],
    this.lastEventId,
    this.error,
  });

  /// Lifecycle status.
  final RpcSubscriptionStatus status;

  /// Latest event, if any arrived.
  final T? data;

  /// Bounded event buffer (only when [RpcSubscriptionController.keepHistoryCount] > 0).
  final List<T> history;

  /// Latest tracked event id, used to resume after reconnects.
  final String? lastEventId;

  /// Failure reason when status is [RpcSubscriptionStatus.error].
  final RpcException? error;

  /// Whether the stream is being opened or re-established.
  bool get isConnecting =>
      status == RpcSubscriptionStatus.connecting ||
      status == RpcSubscriptionStatus.reconnecting;

  /// Whether events are currently flowing.
  bool get isActive => status == RpcSubscriptionStatus.active;

  /// Whether at least one event arrived.
  bool get hasData => data != null;

  /// Whether the stream failed.
  bool get hasError => error != null;
}

/// Binds a subscription stream to a [ValueListenable] of
/// [RpcSubscriptionState] for [ValueListenableBuilder].
///
/// [streamFactory] receives the latest tracked event id so every
/// (re)connect resumes from where the stream left off. Incoming events can
/// auto-invalidate query-cache prefixes via [queryCache] +
/// [invalidatePrefixesOnData], driving dependent queries to refetch.
class RpcSubscriptionController<T>
    extends ValueNotifier<RpcSubscriptionState<T>> {
  /// Creates a subscription controller; call [start] to open the stream.
  RpcSubscriptionController({
    required this.streamFactory,
    this.keepHistoryCount = 0,
    this.onData,
    this.onError,
    this.queryCache,
    this.invalidatePrefixesOnData,
  }) : super(RpcSubscriptionState<T>(history: const <Never>[]));

  /// Opens the stream; `lastEventId` carries the resume point and
  /// `onReconnect` should be forwarded into [RpcSubscriptionOptions.onReconnect]
  /// so the controller can surface a `reconnecting` state when the link chain
  /// re-subscribes after a drop.
  final Stream<T> Function({
    String? lastEventId,
    void Function(int attempt, Object? error)? onReconnect,
  }) streamFactory;

  /// Number of past events kept in [RpcSubscriptionState.history].
  final int keepHistoryCount;

  /// Hook invoked for every incoming event.
  final void Function(T data)? onData;

  /// Hook invoked when the stream fails.
  final void Function(RpcException? error)? onError;

  /// Cache invalidated on every incoming event (optional).
  final RpcQueryCache? queryCache;

  /// Cache prefixes invalidated per event, as path segment lists.
  final List<List<Object?>>? invalidatePrefixesOnData;

  StreamSubscription<T>? _subscription;
  bool _disposed = false;

  /// Opens (or re-opens) the stream from the current resume point.
  void start() => _open();

  /// Closes the stream while keeping the current state and resume point.
  void pause() {
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  /// Re-opens the stream, resuming from the latest tracked event id.
  void resume() => _open();

  /// Re-opens the stream; alias of [resume] with resume semantics.
  void restart() => _open();

  /// Records a tracked event id (wire the client's `onEventId` here).
  void trackEventId(String eventId) {
    if (_disposed) return;
    value = _copyWith(lastEventId: eventId);
  }

  void _handleReconnect(int attempt, Object? error) {
    if (_disposed) return;
    // The chain is re-subscribing; keep the last data, history, and resume
    // point visible until the next event (active) or exhaustion (error).
    value = _copyWith(status: RpcSubscriptionStatus.reconnecting);
  }

  void _open() {
    if (_disposed) return;
    unawaited(_subscription?.cancel());
    value = _copyWith(status: RpcSubscriptionStatus.connecting);
    _subscription = streamFactory(
      lastEventId: value.lastEventId,
      onReconnect: _handleReconnect,
    ).listen(
      (data) {
        if (_disposed) return;
        final history = keepHistoryCount > 0
            ? (<T>[...value.history, data]).sublist(
                (value.history.length + 1 - keepHistoryCount)
                    .clamp(0, value.history.length + 1))
            : <T>[];
        value = _copyWith(
          status: RpcSubscriptionStatus.active,
          data: data,
          history: history,
        );
        onData?.call(data);
        final cache = queryCache;
        if (cache != null) {
          for (final segments
              in invalidatePrefixesOnData ?? const <List<Object?>>[]) {
            cache.invalidate(RpcQueryKey(path: segments.cast<String>()));
          }
        }
      },
      onError: (Object error) {
        if (_disposed) return;
        final exception =
            error is RpcException ? error : RpcNetworkException('$error');
        value =
            _copyWith(status: RpcSubscriptionStatus.error, error: exception);
        onError?.call(exception);
      },
      onDone: () {
        if (_disposed) return;
        value = _copyWith(status: RpcSubscriptionStatus.done);
      },
    );
  }

  RpcSubscriptionState<T> _copyWith({
    RpcSubscriptionStatus? status,
    T? data,
    List<T>? history,
    String? lastEventId,
    RpcException? error,
  }) {
    return RpcSubscriptionState<T>(
      status: status ?? value.status,
      data: data ?? value.data,
      history: history ?? value.history,
      lastEventId: lastEventId ?? value.lastEventId,
      error: error ?? value.error,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
    super.dispose();
  }
}
