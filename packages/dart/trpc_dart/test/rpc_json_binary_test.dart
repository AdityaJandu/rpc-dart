import 'dart:convert';

import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

void main() {
  group('RpcJson.asBytes', () {
    test('passes Uint8List through and copies other int lists', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      expect(RpcJson.asBytes(bytes), same(bytes));
      expect(RpcJson.asBytes(<int>[4, 5]), Uint8List.fromList([4, 5]));
    });

    test('decodes base64 strings from the tRPC convention', () {
      expect(RpcJson.asBytes(base64Encode([1, 2, 3])),
          Uint8List.fromList([1, 2, 3]));
    });

    test('rejects invalid shapes with breadcrumb paths', () {
      expect(
        () => RpcJson.asBytes(42, r'$.payload'),
        throwsA(isA<RpcDecodeException>()
            .having((e) => e.path, 'path', r'$.payload')),
      );
      expect(
        () => RpcJson.asBytes('not base64!!'),
        throwsA(isA<RpcDecodeException>()),
      );
    });
  });

  group('RpcJson.asFile', () {
    test('passes RpcFile through', () {
      final file = RpcFile.bytes('a.png', Uint8List.fromList([1]));
      expect(RpcJson.asFile(file), same(file));
    });

    test('decodes the tRPC superjson file shape', () {
      final file = RpcJson.asFile(<String, Object?>{
        'name': 'a.png',
        'type': 'image/png',
        'data': base64Encode([1, 2]),
      });
      expect(file.filename, 'a.png');
      expect(file.contentType, 'image/png');
      expect(file.length, 2);
    });

    test('rejects invalid shapes with breadcrumb paths', () {
      expect(
        () => RpcJson.asFile('nope', r'$.avatar'),
        throwsA(isA<RpcDecodeException>()
            .having((e) => e.path, 'path', r'$.avatar')),
      );
    });
  });
}
