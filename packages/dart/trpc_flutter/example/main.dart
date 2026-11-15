/// Minimal trpc_flutter usage example: bridging a cache-backed query ref to
/// a native ValueListenable for ValueListenableBuilder.
///
/// Real apps call `listenable()` on generated procedure objects; this example
/// builds the ref directly so the package documentation stands alone.
import 'package:flutter/widgets.dart';
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
    WidgetsApp(color: const Color(0xFF000000), pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) => PageRouteBuilder<T>(settings: settings, pageBuilder: (BuildContext context, Animation<double> _, Animation<double> __) => builder(context)), 
      home: Center(child: ValueListenableBuilder<RpcAsyncState<FakeUser>>(
          valueListenable: ref.listenable,
          builder: (context, state, _) => switch (state) {
            RpcAsyncLoading() => const Text('Loading...'),
            RpcAsyncError() => const Text('failed'),
            RpcAsyncData() => Text('hello ${state.data.name}'),
          },
        ),
      ),
    ),
  );
}
