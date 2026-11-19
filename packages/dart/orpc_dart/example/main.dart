import 'package:orpc_dart/orpc_dart.dart';

/// Minimal oRPC client. Point [endpoint] at your RPCHandler prefix and call
/// procedures through the generated `Api`, or dispatch raw [RpcRequest]s.
Future<void> main() async {
  final endpoint = Uri.parse('https://api.example.com/rpc');
  final client = RpcClient(
    endpoint: endpoint,
    links: [
      LoggingLink(onEvent: (event) => print('${event.event} ${event.path}')),
      OrpcLink(endpoint: endpoint),
    ],
  );

  final data = await client.execute(RpcRequest(
    path: 'planet.find',
    kind: RpcProcedureKind.query,
    input: <String, Object?>{'id': 1},
  ));
  print(data);

  client.cache.invalidate(RpcQueryKey(path: const ['planet']));
}
