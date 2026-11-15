import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trpc_dart/trpc_dart.dart';
import 'package:trpc_flutter/trpc_flutter.dart';

class FakeInput {
  const FakeInput(this.id);

  final String id;

  @override
  bool operator ==(Object other) => other is FakeInput && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

void main() {
  testWidgets('listenable reflects cache states and invalidation refetches',
      (tester) async {
    final cache = RpcQueryCache();
    var fetches = 0;
    final key =
        const RpcQueryKey(path: ['user', 'getById'], input: FakeInput('u1'));
    final ref = cache.watch<FakeInput>(key, () async {
      fetches++;
      return FakeInput('u$fetches');
    });

    final states = <RpcAsyncState<FakeInput>>[];
    final listenable = ref.listenable;
    listenable.addListener(() => states.add(listenable.value));

    await tester.pumpAndSettle();
    expect(listenable.value, isA<RpcAsyncData<FakeInput>>());
    expect((listenable.value as RpcAsyncData<FakeInput>).data.id, 'u1');

    cache.setQueryData<FakeInput>(key, FakeInput('patched'));
    await tester.pump();
    expect((listenable.value as RpcAsyncData<FakeInput>).data.id, 'patched');

    cache.invalidate(const RpcQueryKey(path: ['user']));
    await tester.pumpAndSettle();
    final dataStates = states
        .whereType<RpcAsyncData<FakeInput>>()
        .map((s) => s.data.id)
        .toList();
    expect(dataStates, contains('u2'),
        reason: 'invalidate refetched through the cache');
  });

  testWidgets('ValueListenableBuilder renders loading then data',
      (tester) async {
    final cache = RpcQueryCache();
    final ref = cache.watch<String>(
      const RpcQueryKey(path: ['slow']),
      () async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return 'ready';
      },
    );

    final widget = ValueListenableBuilder<RpcAsyncState<String>>(
      valueListenable: ref.listenable,
      builder: (BuildContext context, RpcAsyncState<String> state, Widget? _) =>
          switch (state) {
        RpcAsyncLoading<String>() => const Text('loading'),
        RpcAsyncError<String>() => const Text('error'),
        RpcAsyncData<String>(:final data) => Text(data),
      },
    );

    await tester.pumpWidget(WidgetsApp(
        color: const Color(0xFF000000),
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PageRouteBuilder<T>(
                settings: settings,
                pageBuilder: (BuildContext context, Animation<double> _,
                        Animation<double> __) =>
                    builder(context)),
        home: widget));
    expect(find.text('loading'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('ready'), findsOneWidget);
  });
}
