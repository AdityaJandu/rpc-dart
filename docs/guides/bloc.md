# Guide: BLoC (Cubit and Bloc)

Wiring generated bindings into Cubits and Blocs, with automatic refresh through the built-in invalidation stream.

## 1. Cubit backed by the cache stream

The cleanest pattern: subscribe the Cubit to `watch(input).stream`. The cache owns fetching, staleness, and invalidation; the Cubit just forwards states.

```dart
import 'package:bloc/bloc.dart';
import 'package:trpc_dart/trpc_dart.dart';
import '../api/api.dart';

sealed class UserState {
  const UserState();
}
class UserLoading extends UserState { const UserLoading(); }
class UserReady extends UserState {
  const UserReady(this.user);
  final UserGetByIdOutput user;
}
class UserFailed extends UserState {
  const UserFailed(this.error);
  final RpcException error;
}

class UserCubit extends Cubit<UserState> {
  UserCubit(this._api, this._userId) : super(const UserLoading());

  final Api _api;
  final String _userId;
  StreamSubscription<RpcAsyncState<UserGetByIdOutput>>? _sub;
  StreamSubscription<RpcQueryKey>? _invalidations;

  void start() {
    final ref = _api.user.getById.watch(UserGetByIdInput(id: _userId));
    _sub = ref.stream.listen((state) => switch (state) {
          RpcAsyncLoading() => emit(const UserLoading()),
          RpcAsyncData(:final data) => emit(UserReady(data)),
          RpcAsyncError(:final error) => emit(UserFailed(error)),
        });
    // React to invalidations anywhere under the 'user' router if you need
    // side effects beyond the cache's own refetch:
    _invalidations = _api.onInvalidate(_api.user.pathKey()).listen((key) {
      // e.g. log analytics, close dependent dialogs, etc.
    });
  }

  Future<void> rename(String newName) async {
    final result = await _api.user.update.safeMutate(
      UpdateUserInput(name: RpcPresent(newName)),
    );
    switch (result) {
      case RpcSuccess():
        _api.invalidate(_api.user.pathKey());   // watched queries refetch; Cubit updates
      case RpcFailure(:final error):
        emit(UserFailed(error));
    }
  }

  @override
  Future<void> close() {
    _sub?.cancel();
    _invalidations?.cancel();
    return super.close();
  }
}
```

## 2. Bloc with explicit events

If the codebase uses event-driven `Bloc`s, the same primitives apply — events map to calls, the cache stream maps to states:

```dart
sealed class UserEvent { const UserEvent(); }
class UserRequested extends UserEvent {
  const UserRequested(this.userId);
  final String userId;
}
class UserRenamed extends UserEvent {
  const UserRenamed(this.name);
  final String name;
}

class UserBloc extends Bloc<UserEvent, UserState> {
  UserBloc(this._api) : super(const UserLoading()) {
    on<UserRequested>(_onRequested);
    on<UserRenamed>(_onRenamed);
  }

  final Api _api;

  Future<void> _onRequested(UserRequested e, Emitter<UserState> emit) async {
    emit(const UserLoading());
    final result = await _api.user.getById.safeQuery(UserGetByIdInput(id: e.userId));
    switch (result) {
      case RpcSuccess(:final data):
        emit(UserReady(data));
      case RpcFailure(:final error):
        emit(UserFailed(error));
    }
  }

  Future<void> _onRenamed(UserRenamed e, Emitter<UserState> emit) async {
    final result = await _api.user.update.safeMutate(UpdateUserInput(name: RpcPresent(e.name)));
    if (result is RpcSuccess<UserGetByIdOutput>) {
      _api.invalidate(_api.user.pathKey());
      add(UserRequested((result as RpcSuccess<UserGetByIdOutput>).data.id));
    }
  }
}
```

## 3. Why invalidate instead of manual state patching

Two valid styles; both are type-safe:

1. **Refetch style (above):** `api.invalidate(key)` marks stale and refetches watched queries. Simplest, always consistent with the server.
2. **Patch style:** write the new model straight into the cache with `setQueryData` for instant UI, then still invalidate in the background:

```dart
final key = _api.user.getById.queryKey(UserGetByIdInput(id: _userId));
final previous = _api.cache.setQueryData(key, ready.copyWith(name: e.name));
await _api.user.update.mutate(UpdateUserInput(name: RpcPresent(e.name)));
// on failure, restore:
// _api.cache.setQueryData(key, previous!);
```

No string keys anywhere: keys are structural (`queryKey(input)`, `pathKey`), so a rename on the backend becomes a compile error here, not a silent no-op.

## 4. Testing

Because `Api` is constructed around an `RpcClient`, tests swap the transport:

```dart
final client = RpcClient(
  endpoint: Uri.parse('http://localhost:${wire.port}/trpc'),
  transformer: RpcTransformer.superjson,
  links: RpcLinkChain([HttpBatchLink()]),
);
final api = Api(client);
final cubit = UserCubit(api, 'u1')..start();
await expectLater(cubit.stream, emitsThrough(isA<UserReady>()));
```

The typed exception hierarchy (`RpcUnauthorizedException`, `RpcBadRequestException.fieldErrors`, ...) makes bloc failure states exact without string matching.
