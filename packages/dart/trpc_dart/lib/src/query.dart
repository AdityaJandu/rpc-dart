import 'dart:async';

import 'exceptions.dart';
import 'link.dart' show RpcCallContext;

/// Structural, deeply comparable query key
///.
class RpcQueryKey {
  const RpcQueryKey({required this.path, this.input});

  final List<String> path;
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
  RpcQueryRef<TOutput> watch(TInput input, {RpcCallContext? context});
}

/// No-input variant for procedures like `user.me`.
abstract interface class RpcWatchableNoInput<TOutput> {
  RpcQueryRef<TOutput> watch({RpcCallContext? context});
}

/// Cache entry state: loading / error / data.
sealed class RpcAsyncState<T> {
  const RpcAsyncState();
}

final class RpcAsyncLoading<T> extends RpcAsyncState<T> {
  const RpcAsyncLoading();
}

final class RpcAsyncError<T> extends RpcAsyncState<T> {
  const RpcAsyncError(this.error);

  final Object error;
}

final class RpcAsyncData<T> extends RpcAsyncState<T> {
  const RpcAsyncData(this.data);

  final T data;
}

/// Cache-backed handle: replaying stream, current state, manual refetch.
class RpcQueryRef<T> {
  RpcQueryRef._(_QueryEntry<T> entry) : _entry = entry;

  final _QueryEntry<T> _entry;

  /// Replays the current state to new listeners, then every change.
  Stream<RpcAsyncState<T>> get stream => _entry.stream;

  RpcAsyncState<T> get state => _entry.state;

  Future<void> refetch() => _entry.refetch();
}

/// Zero-dependency query cache: watch/invalidate/onInvalidate/setQueryData
///. Framework-free.
class RpcQueryCache {
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
    final matches =
        _entries.keys.where((k) => k.matchesPrefix(key)).toList();
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

  void clear() {
    for (final entry in _entries.values) {
      entry.dispose();
    }
    _entries.clear();
  }

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
  bool _started = false;
  bool _disposed = false;
  RpcAsyncState<T> _state;

  RpcAsyncState<T> get state => _state;

  /// Replays the current state to each new listener, then streams changes.
  Stream<RpcAsyncState<T>> get stream => _controller.stream;

  void ensureStarted() {
    if (_started || _disposed) return;
    _started = true;
    _emit(RpcAsyncLoading<T>());
    unawaited(_runFetch());
  }

  @override
  Future<void> refetch() {
    if (_disposed) return Future<void>.value();
    _emit(RpcAsyncLoading<T>());
    return _runFetch();
  }

  @override
  void setData(Object? data) {
    if (data is T) {
      _emit(RpcAsyncData<T>(data));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_controller.close());
  }

  Future<void> _runFetch() async {
    try {
      final data = await _fetch();
      _emit(RpcAsyncData<T>(data));
    } catch (error) {
      if (!_disposed) {
        _emit(RpcAsyncError<T>(error));
      }
    }
  }

  void _emit(RpcAsyncState<T> state) {
    _state = state;
    if (!_controller.isClosed) {
      _controller.add(state);
    }
  }
}

/// Result-typed call surface: never throws. Exhaustive via `switch`.
sealed class RpcResult<T> {
  const RpcResult();
}

final class RpcSuccess<T> extends RpcResult<T> {
  const RpcSuccess(this.data);

  final T data;
}

final class RpcFailure<T> extends RpcResult<T> {
  const RpcFailure(this.error);

  final RpcException error;
}
