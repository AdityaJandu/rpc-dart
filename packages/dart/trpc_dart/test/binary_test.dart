import 'dart:async';

import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

void main() {
  group('RpcFile', () {
    test('bytes source round-trips through readBytes and openStream', () async {
      final file = RpcFile.bytes('avatar.png', Uint8List.fromList([1, 2, 3]),
          contentType: 'image/png');
      expect(file.filename, 'avatar.png');
      expect(file.contentType, 'image/png');
      expect(file.length, 3);
      expect(await file.readBytes(), Uint8List.fromList([1, 2, 3]));
      expect(await file.openStream().toList(), [
        [1, 2, 3]
      ]);
    });

    test('stream source collects chunks and reports known length', () async {
      final controller = StreamController<Uint8List>();
      final file = RpcFile.stream('big.bin', controller.stream,
          length: 5, contentType: 'application/octet-stream');
      controller.add(Uint8List.fromList([1, 2]));
      controller.add(Uint8List.fromList([3, 4, 5]));
      unawaited(controller.close());
      expect(file.length, 5);
      expect(await file.readBytes(), Uint8List.fromList([1, 2, 3, 4, 5]));
    });

    test('toString summarizes without dumping bytes', () {
      final file = RpcFile.bytes('avatar.png', Uint8List(204800),
          contentType: 'image/png');
      final text = file.toString();
      expect(text, contains('avatar.png'));
      expect(text, contains('204800'));
      expect(text, contains('image/png'));
      expect(text.length, lessThan(120));
    });

    test('equal buffered files compare equal', () {
      final a = RpcFile.bytes('a.txt', Uint8List.fromList([1, 2]));
      final b = RpcFile.bytes('a.txt', Uint8List.fromList([1, 2]));
      final c = RpcFile.bytes('a.txt', Uint8List.fromList([9]));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('RpcTransferProgress', () {
    test('fraction is transferred / total when total is known', () {
      const progress = RpcTransferProgress(25, totalBytes: 100);
      expect(progress.fraction, 0.25);
    });

    test('fraction is null when total is unknown or zero', () {
      expect(const RpcTransferProgress(25).fraction, isNull);
      expect(const RpcTransferProgress(0, totalBytes: 0).fraction, isNull);
    });
  });
}
