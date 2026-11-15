import 'dart:async';

import 'exceptions.dart';
import 'link.dart' show RpcCallContext;

/// Structural, deeply comparable query key.
class RpcQueryKey {
  /// Creates a query key with path segments and optional input.
  const RpcQueryKey({required this.path, this.input});

  /// Path segments identifying the query, e.g. `['user', 'getById']`.
  final List<String> path;

  /// Optional input payload for this query key.
  final Object? input;

  /// True when this key lives under [prefix] (segment-based; no string
  /// parsing). A prefix carrying an input additionally requires input
  /// equality.
  bool matchesPrefix(RpcQueryKey prefix) {
    if (prefix.path.length > path.length) return false;
    for (var i = 0; i < prefix.path.length; i++) {
      if (path[i] != prefix.path[i]) return false;
    }
    return prefix.input == null || prefix.input == input;
  }

  @override
  bool operator ==(Object other) =>
      other is RpcQueryKey &&
      _listEquals(other.path, path) &&
      other.input == input;

  @override
  int get hashCode => Object.hash(Object.hashAll(path), input);

  @override
  String toString() => 'RpcQueryKey(${path.join('.')})';
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Contract implemented by generated query procedure classes so the Flutter
/// bridge can offer `listenable(input)` on them without knowing their types.
abstract interface class RpcWatchable<TInput, TOutput> {
  /// Watches the procedure with [input] and returns an [RpcQueryRef].
  RpcQueryRef<TOutput> watch(TInput input, {RpcCallContext? context});
}

/// No-input variant for procedures like `user.me`.
abstract interface class RpcWatchableNoInput<TOutput> {
  /// Watches the procedure without input and returns an [RpcQueryRef].
  RpcQueryRef<TOutput> watch({RpcCallContext? context});
}

/// Cache entry state: loading / error / data.
sealed class RpcAsyncState<T> {
  /// Base constructor for async state variants.
  const RpcAsyncState();
}

/// Indicates a query is currently fetching or refetching.
final class RpcAsyncLoading<T> extends RpcAsyncState<T> {
  /// Creates a loading state.
  const RpcAsyncLoading();
}

/// Indicates a query fetch failed with [error].
final class RpcAsyncError<T> extends RpcAsyncState<T> {
  /// Creates an error state with the underlying error.
  const RpcAsyncError(this.error);

  /// The error thrown during fetch.
  final Object error;
}

/// Indicates a query fetch succeeded with [data].
final class RpcAsyncData<T> extends RpcAsyncState<T> {
  /// Creates a data state carrying [data].
  const RpcAsyncData(this.data);

  /// The resolved data payload.
  final T data;
}

/// Cache-backed handle: replaying stream, current state, manual refetch.
class RpcQueryRef<T> {
  RpcQueryRef._(_QueryEntry<T> entry) : _entry = entry;

  final _QueryEntry<T> _entry;

  /// Replays the current state to new listeners, then emits every transition.
  Stream<RpcAsyncState<T>> get stream => _entry.stream;

  /// Current synchronous snapshot state.
  RpcAsyncState<T> get state => _entry.state;

  /// Triggers an immediate background refetch of this query.
  Future<void> refetch() => _entry.refetch();
}

/// Zero-dependency query cache: watch/invalidate/onInvalidate/setQueryData.
class RpcQueryCache {
  /// Creates an empty query cache.
  RpcQueryCache();

  final Map<RpcQueryKey, _EntryBase> _entries = {};
  final StreamController<RpcQueryKey> _invalidations =
      StreamController<RpcQueryKey>.broadcast();

  /// Registers (or joins) a query entry. The first creation triggers the
  /// initial fetch; the ref's stream replays current state to new listeners.
  RpcQueryRef<T> watch<T>(RpcQueryKey key, Future<T> Function() fetch) {
    final existing = _entries[key];
    if (existing is _QueryEntry<T>) {
      existing.ensureStarted();
      return RpcQueryRef<T>._(existing);
    }
    final entry = _QueryEntry<T>(key, fetch);
    _entries[key] = entry;
    entry.ensureStarted();
    return RpcQueryRef<T>._(entry);
  }

  /// Marks matching entries stale, refetches active watchers, and emits the
  /// invalidated keys on the invalidation stream.
  void invalidate(RpcQueryKey key) {
    final matches = _entries.keys.where((k) => k.matchesPrefix(key)).toList();
    for (final match in matches) {
      _invalidations.add(match);
      _entries[match]?.refetch();
    }
  }

  /// Stream of invalidated keys, optionally filtered by prefix.
  Stream<RpcQueryKey> onInvalidate([RpcQueryKey? prefix]) {
    if (prefix == null) return _invalidations.stream;
    return _invalidations.stream.where((k) => k.matchesPrefix(prefix));
  }

  /// Direct cache write without a network round trip (optimistic updates).
  void setQueryData<T>(RpcQueryKey key, T data) {
    final entry = _entries[key];
    if (entry is _QueryEntry<T>) {
      entry.setData(data);
    }
  }

  /// Current cached data, if any and if loaded.
  T? dataOf<T>(RpcQueryKey key) {
    final entry = _entries[key];
    if (entry is _QueryEntry<T>) {
      final state = entry.state;
      if (state is RpcAsyncData<T>) return state.data;
    }
    return null;
  }

  /// Clears all entries from the cache and disposes their controllers.
  void clear() {
    for (final entry in _entries.values) {
      entry.dispose();
    }
    _entries.clear();
  }

  /// Disposes all cache entries and closes the invalidation stream.
  void dispose() {
    clear();
    unawaited(_invalidations.close());
  }
}

abstract class _EntryBase {
  RpcQueryKey get key;

  void refetch();

  void setData(Object? data);

  void dispose();
}

final class _QueryEntry<T> extends _EntryBase {
  _QueryEntry(this.key, this._fetch) : _state = RpcAsyncLoading<T>();

  @override
  final RpcQueryKey key;

  final Future<T> Function() _fetch;
  late final StreamController<RpcAsyncState<T>> _controller =
      StreamController<RpcAsyncState<T>>.broadcast(onListen: () {
    if (!_controller.isClosed) {
      _controller.add(_state);
    }
  });

  RpcAsyncState<T> _state;
  bool _started = false;

  RpcAsyncState<T> get state => _state;
  Stream<RpcAsyncState<T>> get stream => _controller.stream;

  void ensureStarted() {
    if (_started) return;
    _started = true;
    unawaited(refetch());
  }

  @override
  void setData(Object? data) {
    if (data is T) {
      _state = RpcAsyncData<T>(data);
      if (!_controller.isClosed) {
        _controller.add(_state);
      }
    }
  }

  @override
  Future<void> refetch() async {
    _state = const RpcAsyncLoading();
    if (!_controller.isClosed) {
      _controller.add(_state);
    }
    try {
      final value = await _fetch();
      _state = RpcAsyncData<T>(value);
      if (!_controller.isClosed) {
        _controller.add(_state);
      }
    } catch (error) {
      _state = RpcAsyncError<T>(error);
      if (!_controller.isClosed) {
        _controller.add(_state);
      }
    }
  }

  @override
  void dispose() {
    unawaited(_controller.close());
  }
}

/// Result-typed call surface: never throws. Exhaustive via Dart 3 `switch`.
sealed class RpcResult<T> {
  /// Base constructor for result variants.
  const RpcResult();
}

/// Indicates a procedure call succeeded with [data].
final class RpcSuccess<T> extends RpcResult<T> {
  /// Creates a success result carrying [data].
  const RpcSuccess(this.data);

  /// The successful return value.
  final T data;
}

/// Indicates a procedure call failed with [error].
final class RpcFailure<T> extends RpcResult<T> {
  /// Creates a failure result carrying [error].
  const RpcFailure(this.error);

  /// The error thrown by the procedure.
  final RpcException error;
}
