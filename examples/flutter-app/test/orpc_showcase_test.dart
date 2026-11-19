import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orpc_dart/orpc_dart.dart';

import 'package:example_flutter_app/src/orpc_api/api.dart';
import 'package:example_flutter_app/src/orpc_showcase.dart';

/// Canned oRPC responses keyed by procedure path; exercises the generated
/// bindings and the showcase without a live server.
final class _FakeOrpcLink extends RpcLink {
  @override
  bool get isTermination => true;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) async {
    switch (request.path) {
      case 'planet.find':
        return <String, Object?>{
          'id': 1.0,
          'name': 'Earth',
          'discoveredAt': DateTime.utc(2022, 1, 1),
          'mass': BigInt.from(5972),
        };
      case 'uploads.avatar':
        return <String, Object?>{
          'name': 'demo.png',
          'size': 256 * 1024,
          'note': 'showcase',
        };
      case 'files.download':
        return RpcFile.bytes('earth.png', Uint8List.fromList([10, 20, 30, 40]),
            contentType: 'image/png');
      case 'files.stream':
        return Stream<Uint8List>.fromIterable([
          Uint8List.fromList([1, 2]),
          Uint8List.fromList([3]),
        ]);
      default:
        throw StateError('unexpected path ${request.path}');
    }
  }

  @override
  Stream<Object?> invokeStream(RpcRequest request, RpcStreamLinkNext next) {
    return Stream<Object?>.fromIterable([
      <String, Object?>{'tick': 0.0, 'at': DateTime.utc(2026, 1, 1)},
      <String, Object?>{'tick': 1.0, 'at': DateTime.utc(2026, 1, 1)},
    ]);
  }
}

void main() {
  testWidgets('oRPC showcase drives queries, transfers, and ticks',
      (tester) async {
    final api = Api(RpcClient(
      endpoint: Uri.parse('http://127.0.0.1:0/rpc'),
      links: [_FakeOrpcLink()],
    ));
    await tester.pumpWidget(WidgetsApp(
      color: const Color(0xFF000000),
      pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
          PageRouteBuilder<T>(
        settings: settings,
        pageBuilder: (context, _, __) => builder(context),
      ),
      home: OrpcShowcasePage(api: api),
    ));

    await tester.tap(find.text('Query planet'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Earth'), findsOneWidget);

    await tester.tap(find.text('Upload file'));
    await tester.pumpAndSettle();
    expect(find.textContaining('262144 bytes'), findsOneWidget);

    await tester.tap(find.text('Download file'));
    await tester.pumpAndSettle();
    expect(find.textContaining('earth.png'), findsOneWidget);

    await tester.tap(find.text('Stream bytes'));
    await tester.pumpAndSettle();
    expect(find.text('streamed 3 bytes'), findsOneWidget);

    await tester.tap(find.text('Start ticks'));
    await tester.pumpAndSettle();
    expect(find.text('ticks: 0, 1'), findsOneWidget);
  });

  test('generated error union decodes a defined oRPC error via fromException',
      () async {
    final api = Api(RpcClient(
      endpoint: Uri.parse('http://127.0.0.1:0/rpc'),
      links: [_DefinedErrorLink()],
    ));
    final result =
        await api.planet.find.safeQuery(const PlanetFindInput(id: 999));
    switch (result) {
      case RpcFailure(:final error):
        final typed = PlanetFindError.fromException(error);
        if (typed is PlanetFindErrorNOTFOUND) {
          expect(typed.data?.id, 999);
        } else {
          fail('expected PlanetFindErrorNOTFOUND, got $typed');
        }
      default:
        fail('expected a defined NOT_FOUND failure');
    }
  });
}

final class _DefinedErrorLink extends RpcLink {
  @override
  bool get isTermination => true;

  @override
  Future<Object?> invoke(RpcRequest request, RpcLinkNext next) async {
    throw RpcException.fromOrpcWire(<String, Object?>{
      'defined': true,
      'code': 'NOT_FOUND',
      'status': 404,
      'message': 'no planet',
      'data': <String, Object?>{'id': 999},
    });
  }
}
