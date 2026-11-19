import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orpc_flutter/orpc_flutter.dart';

void main() {
  test('exports the oRPC runtime and the Flutter bridge', () {
    final controller = RpcSubscriptionController<int>(
      streamFactory: ({lastEventId, onReconnect}) => const Stream<int>.empty(),
    );
    expect(controller.value.status, RpcSubscriptionStatus.idle);
    controller.dispose();

    final endpoint = Uri.parse('https://x.dev/rpc');
    final link = OrpcLink(endpoint: endpoint);
    expect(RpcFile.bytes('a.png', Uint8List.fromList([1])).filename, 'a.png');
    link.close();
  });

  test('does not export the tRPC-only HttpBatchLink', () {
    final repoRoot = Directory.current.parent.parent.parent.path;
    final dir =
        Directory.systemTemp.createTempSync('orpc_flutter_export_probe');
    try {
      File('${dir.path}/pubspec.yaml').writeAsStringSync('''
name: probe
publish_to: none
environment:
  sdk: ">=3.6.0 <4.0.0"
dependencies:
  flutter:
    sdk: flutter
  orpc_flutter:
    path: ${Directory.current.path}
dependency_overrides:
  orpc_dart:
    path: $repoRoot/packages/dart/orpc_dart
  trpc_dart:
    path: $repoRoot/packages/dart/trpc_dart
  trpc_flutter:
    path: $repoRoot/packages/dart/trpc_flutter
''');
      File('${dir.path}/probe.dart').writeAsStringSync('''
import 'package:orpc_flutter/orpc_flutter.dart';
void main() {
  HttpBatchLink(endpoint: Uri.parse('https://x.dev'));
}
''');
      final pubGet = Process.runSync('flutter', ['pub', 'get'],
          workingDirectory: dir.path);
      expect(pubGet.exitCode, 0, reason: '${pubGet.stdout}\n${pubGet.stderr}');
      final result = Process.runSync('flutter', ['analyze', 'probe.dart'],
          workingDirectory: dir.path);
      expect(result.exitCode, isNot(0),
          reason: 'HttpBatchLink must not be visible through orpc_flutter');
      expect('${result.stdout}', contains('HttpBatchLink'));
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
