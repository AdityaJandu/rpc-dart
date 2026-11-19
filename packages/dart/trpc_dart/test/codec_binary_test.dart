import 'dart:convert';

import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

void main() {
  group('tRPC superjson binary annotations', () {
    test('decodes Uint8Array annotations from base64', () {
      final out = superjsonDecode(<String, Object?>{
        'json': <String, Object?>{
          'payload': base64Encode([1, 2, 3])
        },
        'meta': <String, Object?>{
          'values': <String, Object?>{
            'payload': ['custom', 'Uint8Array'],
          },
        },
      })! as Map<String, Object?>;
      expect(out['payload'], Uint8List.fromList([1, 2, 3]));
    });

    test('decodes File annotations into RpcFile', () {
      final out = superjsonDecode(<String, Object?>{
        'json': <String, Object?>{
          'avatar': <String, Object?>{
            'name': 'a.png',
            'type': 'image/png',
            'data': base64Encode([9]),
          },
        },
        'meta': <String, Object?>{
          'values': <String, Object?>{
            'avatar': ['custom', 'File'],
          },
        },
      })! as Map<String, Object?>;
      final file = out['avatar']! as RpcFile;
      expect(file.filename, 'a.png');
      expect(file.contentType, 'image/png');
    });

    test('encodes Uint8List as base64 with a Uint8Array annotation', () {
      final envelope = superjsonEncode(<String, Object?>{
        'payload': Uint8List.fromList([1, 2])
      })! as Map<String, Object?>;
      final json = envelope['json']! as Map<String, Object?>;
      expect(json['payload'], base64Encode([1, 2]));
      final meta = envelope['meta']! as Map<String, Object?>;
      final values = meta['values']! as Map<String, Object?>;
      expect(values['payload'], [
        ['custom', 'Uint8Array']
      ]);
    });

    test('encodes buffered RpcFile with a File annotation', () {
      final envelope = superjsonEncode(<String, Object?>{
        'avatar': RpcFile.bytes('a.png', Uint8List.fromList([7]),
            contentType: 'image/png'),
      })! as Map<String, Object?>;
      final json = envelope['json']! as Map<String, Object?>;
      final avatar = json['avatar']! as Map<String, Object?>;
      expect(avatar['name'], 'a.png');
      expect(avatar['type'], 'image/png');
      expect(avatar['data'], base64Encode([7]));
      final meta = envelope['meta']! as Map<String, Object?>;
      final values = meta['values']! as Map<String, Object?>;
      expect(values['avatar'], [
        ['custom', 'File']
      ]);
    });

    test('round-trips binary fields through encode and decode', () {
      final tree = <String, Object?>{
        'payload': Uint8List.fromList([1, 2, 3]),
        'avatar': RpcFile.bytes('a.png', Uint8List.fromList([4]),
            contentType: 'image/png'),
      };
      final out =
          superjsonDecode(superjsonEncode(tree))! as Map<String, Object?>;
      expect(out['payload'], Uint8List.fromList([1, 2, 3]));
      expect((out['avatar']! as RpcFile).filename, 'a.png');
    });

    test('rejects streaming RpcFile on the buffered superjson wire', () {
      expect(
        () => superjsonEncode(<String, Object?>{
          'avatar': RpcFile.stream('s.bin', const Stream<Uint8List>.empty()),
        }),
        throwsA(isA<RpcException>()),
      );
    });

    test('root binary inputs nest the tuple annotation (superjson wire)', () {
      final envelope =
          superjsonEncode(Uint8List.fromList([1, 2]))! as Map<String, Object?>;
      expect(envelope['json'], base64Encode([1, 2]));
      final meta = envelope['meta']! as Map<String, Object?>;
      expect(meta['values'], [
        ['custom', 'Uint8Array']
      ]);
    });

    test('root binary responses decode through nested tuple annotations', () {
      final out = superjsonDecode(<String, Object?>{
        'json': base64Encode([1, 2, 3]),
        'meta': <String, Object?>{
          'values': [
            ['custom', 'Uint8Array']
          ],
          'v': 1,
        },
      });
      expect(out, Uint8List.fromList([1, 2, 3]));
    });

    test('root simple annotations still decode (Date)', () {
      final out = superjsonDecode(<String, Object?>{
        'json': '2026-01-01T00:00:00.000Z',
        'meta': <String, Object?>{
          'values': ['Date'],
          'v': 1,
        },
      });
      expect(out, DateTime.utc(2026, 1, 1));
    });

    test('nested tuple annotations decode through the walker wrapper', () {
      final out = superjsonDecode(<String, Object?>{
        'json': <String, Object?>{
          'avatar': <String, Object?>{
            'name': 'a.png',
            'type': 'image/png',
            'data': base64Encode([9]),
          },
        },
        'meta': <String, Object?>{
          'values': <String, Object?>{
            'avatar': [
              ['custom', 'File']
            ],
          },
          'v': 1,
        },
      })! as Map<String, Object?>;
      expect((out['avatar']! as RpcFile).filename, 'a.png');
    });
  });
}
