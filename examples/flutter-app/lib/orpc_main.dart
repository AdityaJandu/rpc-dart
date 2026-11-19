import 'package:flutter/widgets.dart';
import 'package:orpc_dart/orpc_dart.dart';

import 'src/orpc_api/api.dart';
import 'src/orpc_showcase.dart';

/// Composition root for the oRPC showcase. Run with:
///   flutter run -t lib/orpc_main.dart
/// against examples/orpc-fastify (port 8788).
final orpcClient = RpcClient(
  endpoint: Uri.parse('http://127.0.0.1:8788/rpc'),
  links: [
    LoggingLink(
        onEvent: (event) => debugPrint(
            '[orpc] ${event.event} ${event.path} ${event.durationMs}ms')),
    ContextLink(),
    RetryLink(policy: const RpcRetryPolicy(maxAttempts: 2)),
    OrpcLink(endpoint: Uri.parse('http://127.0.0.1:8788/rpc')),
  ],
);

void main() {
  runApp(
    WidgetsApp(
      color: const Color(0xFF000000),
      pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
          PageRouteBuilder<T>(
        settings: settings,
        pageBuilder:
            (BuildContext context, Animation<double> _, Animation<double> __) =>
                builder(context),
      ),
      home: OrpcShowcasePage(api: Api(orpcClient)),
    ),
  );
}
