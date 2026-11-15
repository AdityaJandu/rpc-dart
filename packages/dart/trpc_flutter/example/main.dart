/// Minimal trpc_flutter usage example: bridging a cache-backed query ref to
/// a native ValueListenable for ValueListenableBuilder.
///
/// Real apps call `listenable()` on generated procedure objects; this example
/// builds the ref directly so the package documentation stands alone.
import 'package:flutter/material.dart';
import 'package:trpc_dart/trpc_dart.dart';
import 'package:trpc_flutter/trpc_flutter.dart';

class FakeUser {
  const FakeUser(this.name);
  final String name;

  @override
  bool operator ==(Object other) => other is FakeUser && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

Future<void> main() async {
  final cache = RpcQueryCache();
  final ref = cache.watch<FakeUser>(
    const RpcQueryKey(path: ['user', 'me']),
    () async => const FakeUser('Aditya'),
  );

  runApp(
    MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<RpcAsyncState<FakeUser>>(
          valueListenable: ref.listenable,
          builder: (context, state, _) => switch (state) {
            RpcAsyncLoading() => const CircularProgressIndicator(),
            RpcAsyncError() => const Text('failed'),
            RpcAsyncData() => Text('hello ${state.data.name}'),
          },
        ),
      ),
    ),
  );
}
