import 'package:flutter/widgets.dart';
import 'package:trpc_dart/trpc_dart.dart';
import 'package:trpc_flutter/trpc_flutter.dart';

import 'src/api/api.dart';

/// Composition root: one client, one generated [Api].
final client = RpcClient(
  endpoint: Uri.parse('http://127.0.0.1:8787/trpc'),
  transformer: RpcTransformer.superjson,
  defaultHeaders: const {'x-app': 'showcase'},
  links: [
    LoggingLink(onEvent: (event) => debugPrint('[rpc] ${event.event} ${event.path} ${event.durationMs}ms')),
    AuthLink(
      getHeaders: () async => {'authorization': 'Bearer demo-token'},
      onUnauthorized: () async {
        // single-flight refresh hook; demo token never expires
        return null;
      },
    ),
    ContextLink(dynamicHeaders: () async => {'x-app-version': '1.0.0'}),
    RetryLink(policy: const RpcRetryPolicy(maxAttempts: 2)),
    HttpBatchLink(endpoint: Uri.parse('http://127.0.0.1:8787/trpc')),
  ],
);

final api = Api(client);

void main() {
  runApp(const ShowcaseApp());
}

class ShowcaseApp extends StatelessWidget {
  const ShowcaseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      color: const Color(0xFF000000),
      pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
          PageRouteBuilder<T>(
        settings: settings,
        pageBuilder: (BuildContext context, Animation<double> _, Animation<double> __) =>
            builder(context),
      ),
      home: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('rpc-dart showcase'),
            const UserCard(),
            GestureDetector(
              onTap: () async {
                await api.user.update.mutate(
                  const UserUpdateInput(promoCode: 'demo', nickname: RpcNull()),
                );
                api.invalidate(api.user.pathKey);
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Update nickname (PATCH semantics)'),
              ),
            ),
            GestureDetector(
              onTap: () async {
                final page = await api.posts.list.query(
                  const PostsListInput(sort: PostsListInputSort.asc),
                );
                debugPrint('page1: ${page.items.map((p) => p.id).join(',')}');
                if (page.nextCursor != null) {
                  final page2 = await api.posts.list.query(
                    PostsListInput(sort: PostsListInputSort.asc, cursor: page.nextCursor),
                  );
                  debugPrint('page2: ${page2.items.map((p) => p.id).join(',')}');
                }
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Refetch posts'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Reactive card over the built-in cache via the ValueListenable bridge.
class UserCard extends StatelessWidget {
  const UserCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RpcAsyncState<UserGetByIdOutput>>(
      valueListenable: api.user.me.listenable(),
      builder: (context, state, _) => switch (state) {
        RpcAsyncLoading() => const Text('Loading...'),
        RpcAsyncError(:final error) => Text('error: $error'),
        RpcAsyncData(:final data) => Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(data.name),
                  Text(
                    '${data.id} - ${data.receipt.runtimeType.toString().split('.').last.replaceAll("Receipt", "").replaceAll("Unknown", "?")}',
                  ),
                ],
              ),
              const Text('-'),
            ],
          ),
      },
    );
  }
}
