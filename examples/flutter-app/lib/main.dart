import 'package:flutter/material.dart';
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
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('rpc-dart showcase')),
        body: ListView(
          children: [
            const UserCard(),
            ListTile(
              title: const Text('Update nickname (PATCH semantics)'),
              onTap: () async {
                await api.user.update.mutate(
                  const UserUpdateInput(promoCode: 'demo', nickname: RpcNull()),
                );
                api.invalidate(api.user.pathKey);
              },
            ),
            ListTile(
              title: const Text('Refetch posts'),
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
        RpcAsyncLoading() => const CircularProgressIndicator(),
        RpcAsyncError(:final error) => Text('error: $error'),
        RpcAsyncData(:final data) => ListTile(
            title: Text(data.name),
            subtitle: Text('${data.id} - ${data.receipt.runtimeType.toString().split('.').last.replaceAll("Receipt", "").replaceAll("Unknown", "?")}'),
            trailing: Text('-'),
          ),
      },
    );
  }
}
