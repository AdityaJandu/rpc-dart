import 'dart:io';

import 'package:orpc_dart/orpc_dart.dart';
import 'package:test/test.dart';

void main() {
  test('exports the oRPC runtime surface', () {
    final endpoint = Uri.parse('https://x.dev/rpc');
    final link = OrpcLink(endpoint: endpoint);
    final client = RpcClient(endpoint: endpoint, links: [link]);
    final file = RpcFile.bytes('a.png', Uint8List.fromList([1, 2]));
    expect(client, isA<RpcClient>());
    expect(file.filename, 'a.png');
    expect(const RpcCallContext(), isA<RpcCallContext>());
    expect(RpcException('x', code: 'NOT_FOUND'), isA<RpcException>());
    expect(RpcJson.asString('ok'), 'ok');
    expect(rpcDeepEquals([1, 2], [1, 2]), isTrue);
    link.close();
  });

  test('does not export the tRPC-only HttpBatchLink', () {
    final repoRoot = Directory.current.parent.parent.parent.path;
    final dir = Directory.systemTemp.createTempSync('orpc_dart_export_probe');
    try {
      File('${dir.path}/pubspec.yaml').writeAsStringSync('''
name: probe
publish_to: none
environment:
  sdk: ">=3.6.0 <4.0.0"
dependencies:
  orpc_dart:
    path: ${Directory.current.path}
dependency_overrides:
  trpc_dart:
    path: $repoRoot/packages/dart/trpc_dart
''');
      File('${dir.path}/probe.dart').writeAsStringSync('''
import 'package:orpc_dart/orpc_dart.dart';
void main() {
  HttpBatchLink(endpoint: Uri.parse('https://x.dev'));
}
''');
      final pubGet =
          Process.runSync('dart', ['pub', 'get'], workingDirectory: dir.path);
      expect(pubGet.exitCode, 0, reason: '${pubGet.stdout}\n${pubGet.stderr}');
      final result = Process.runSync('dart', ['analyze', 'probe.dart'],
          workingDirectory: dir.path);
      expect(result.exitCode, isNot(0),
          reason: 'HttpBatchLink must not be visible through orpc_dart');
      expect('${result.stdout}', contains('HttpBatchLink'));
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
