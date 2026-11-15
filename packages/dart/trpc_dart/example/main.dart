/// Minimal trpc_dart usage example: client setup, a typed query, and a
/// mutation with three-state optionality.
///
/// Real apps use the generated per-project bindings (see
/// examples/flutter-app); this example calls the transport directly so the
/// package documentation stands alone.
import 'package:trpc_dart/trpc_dart.dart';

Future<void> main() async {
  final client = RpcClient(
    endpoint: Uri.parse('https://api.example.com/trpc'),
    transformer: RpcTransformer.superjson,
    defaultHeaders: const {'authorization': 'Bearer demo-token'},
    links: [
      LoggingLink(
          onEvent: (event) => print('[rpc] ${event.event} ${event.path}')),
      RetryLink(policy: const RpcRetryPolicy(maxAttempts: 3)),
      HttpBatchLink(endpoint: Uri.parse('https://api.example.com/trpc')),
    ],
  );

  // Direct transport call: the batch link demultiplexes and decodes the
  // SuperJSON envelope into a Dart-native tree (DateTime, BigInt, ...).
  final data = await client.execute(const RpcRequest(
    path: 'user.getById',
    kind: RpcProcedureKind.query,
    input: {'id': 'u1'},
  ));
  print('user: $data');

  // Zero-cast decoding with field breadcrumbs on malformed payloads.
  try {
    print(RpcJson.asString(data, 'user.name'));
  } on RpcDecodeException catch (error) {
    print('decode failed at ${error.path}: expected ${error.expected}');
  }

  client.cache.dispose();
}
