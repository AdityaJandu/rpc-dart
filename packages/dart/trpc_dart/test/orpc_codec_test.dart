import 'dart:convert';

import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

void main() {
  const codec = OrpcCodec();

  group('OrpcCodec.serialize (oRPC 1.x numeric-tag wire)', () {
    test('encodes Date, BigInt, NaN, URL, RegExp, Set, Map with numeric tags',
        () {
      final result = codec.serialize(<String, Object?>{
        'id': BigInt.from(10),
        'at': DateTime.utc(2022, 1, 1),
        'n': double.nan,
        'url': Uri.parse('https://x.dev/a'),
        'set': <int>{1, 2},
        'map': <int, String>{1: 'a'},
      });
      final json = result.json! as Map<String, Object?>;
      expect(json['id'], '10');
      expect(json['at'], '2022-01-01T00:00:00.000Z');
      expect(json['n'], isNull);
      expect(json['url'], 'https://x.dev/a');
      expect(json['set'], [1, 2]);
      expect(json['map'], [
        [1, 'a']
      ]);
      expect(result.meta, contains(equals([0, 'id'])));
      expect(result.meta, contains(equals([1, 'at'])));
      expect(result.meta, contains(equals([2, 'n'])));
      expect(result.meta, contains(equals([4, 'url'])));
      expect(result.meta, contains(equals([6, 'set'])));
      expect(result.meta, contains(equals([7, 'map'])));
      expect(result.hasFiles, isFalse);
      expect(result.envelope(), {
        'json': json,
        'meta': result.meta,
      });
    });

    test('string-keyed maps stay plain JSON objects (record wire shape)', () {
      final result = codec.serialize(<String, Object?>{
        'record': <String, int>{'k': 1}
      });
      final json = result.json! as Map<String, Object?>;
      expect(json['record'], {'k': 1});
      expect(result.meta, isEmpty);
    });

    test('extracts RpcFile and Uint8List nodes into maps and indexed blobs',
        () {
      final result = codec.serialize(<String, Object?>{
        'name': 'Earth',
        'thumbnail': RpcFile.bytes('t.png', Uint8List.fromList([1]),
            contentType: 'image/png'),
        'images': [
          Uint8List.fromList([2, 3]),
        ],
      });
      expect(result.hasFiles, isTrue);
      expect(result.maps, [
        ['thumbnail'],
        ['images', 0],
      ]);
      expect(result.blobs.length, 2);
      expect(result.blobs[0].filename, 't.png');
      expect(result.blobs[1].filename, 'blob');
      final json = result.json! as Map<String, Object?>;
      expect(json['thumbnail'], <String, Object?>{});
      expect((json['images']! as List<Object?>)[0], <String, Object?>{});
      final field = jsonDecode(result.formDataField()) as Map<String, Object?>;
      expect(field['maps'], result.maps);
      expect(field['json'], json);
    });

    test('nested paths use string keys and int indices', () {
      final result = codec.serialize(<String, Object?>{
        'items': [
          <String, Object?>{'when': DateTime.utc(2020)},
        ],
      });
      expect(result.meta, contains(equals([1, 'items', 0, 'when'])));
    });

    test('undefined input serializes to an empty envelope', () {
      final result = codec.serialize(null);
      expect(result.envelope(), <String, Object?>{});
    });
  });

  group('OrpcCodec.deserialize', () {
    test('restores numeric-tag types from a captured 1.16.3 envelope', () {
      final out = codec.deserialize(<String, Object?>{
        'json': <String, Object?>{
          'id': '10',
          'at': '2022-01-01T00:00:00.000Z',
          'n': null,
          'url': 'https://x.dev/a',
          'set': [1, 2],
          'map': [
            ['k', 1]
          ],
          'arr': [1, null, 'x'],
        },
        'meta': [
          [0, 'id'],
          [1, 'at'],
          [2, 'n'],
          [4, 'url'],
          [6, 'set'],
          [7, 'map'],
          [3, 'arr', 1],
        ],
      })! as Map<String, Object?>;
      expect(out['id'], BigInt.from(10));
      expect(out['at'], DateTime.utc(2022, 1, 1));
      expect((out['n']! as double).isNaN, isTrue);
      expect(out['url'], Uri.parse('https://x.dev/a'));
      expect(out['set'], <int>{1, 2});
      expect(out['map'], <String, int>{'k': 1});
      expect(out['arr'], [1, null, 'x']);
    });

    test('accepts string handler keys (oRPC 2.x forward compatibility)', () {
      final out = codec.deserialize(<String, Object?>{
        'json': <String, Object?>{
          'id': '7',
          'inf': 'Infinity',
          'ninf': '-Infinity',
        },
        'meta': [
          ['bigint', 'id'],
          ['infinity', 'inf'],
          ['infinity', 'ninf'],
        ],
      })! as Map<String, Object?>;
      expect(out['id'], BigInt.from(7));
      expect(out['inf'], double.infinity);
      expect(out['ninf'], double.negativeInfinity);
    });

    test('restores indexed blobs through maps descriptors', () {
      final out = codec.deserialize(
        <String, Object?>{
          'json': <String, Object?>{
            'thumbnail': <String, Object?>{},
            'images': [<String, Object?>{}],
          },
          'maps': [
            ['thumbnail'],
            ['images', 0],
          ],
        },
        getBlob: (i) => RpcFile.bytes('f$i.png', Uint8List.fromList([i])),
      )! as Map<String, Object?>;
      expect((out['thumbnail']! as RpcFile).filename, 'f0.png');
      expect(((out['images']! as List<Object?>)[0]! as RpcFile).filename,
          'f1.png');
    });

    test('empty-path maps replace the root with the blob (root File wire)', () {
      final out = codec.deserialize(
        <String, Object?>{
          'json': <String, Object?>{},
          'maps': [<Object?>[]],
        },
        getBlob: (i) => RpcFile.bytes('earth.png', Uint8List.fromList([1])),
      );
      expect(out, isA<RpcFile>());
      expect((out! as RpcFile).filename, 'earth.png');
    });

    test('root-level meta tags restore scalar roots', () {
      final out = codec.deserialize(<String, Object?>{
        'json': '2022-01-01T00:00:00.000Z',
        'meta': [
          [1],
        ],
      });
      expect(out, DateTime.utc(2022, 1, 1));
    });

    test('rejects meta paths through nonexistent segments (CVE-2026-28794)',
        () {
      expect(
        () => codec.deserialize(<String, Object?>{
          'json': <String, Object?>{'a': 1},
          'meta': [
            [0, 'missing', 'deep'],
          ],
        }),
        throwsA(isA<RpcDecodeException>()),
      );
      expect(
        () => codec.deserialize(<String, Object?>{
          'json': <String, Object?>{'a': 1},
          'meta': [
            [0, '__proto__', 'polluted'],
          ],
        }),
        throwsA(isA<RpcDecodeException>()),
      );
    });

    test('rejects maps paths through nonexistent segments', () {
      expect(
        () => codec.deserialize(
          <String, Object?>{
            'json': <String, Object?>{'a': 1},
            'maps': [
              ['__proto__', 'role'],
            ],
          },
          getBlob: (i) => RpcFile.bytes('x', Uint8List(0)),
        ),
        throwsA(isA<RpcDecodeException>()),
      );
    });

    test('rejects oversized bigint strings beyond the 4300-digit limit', () {
      expect(
        () => codec.deserialize(<String, Object?>{
          'json': <String, Object?>{'big': '9' * 4301},
          'meta': [
            [0, 'big'],
          ],
        }),
        throwsA(isA<RpcDecodeException>()),
      );
    });

    test('rejects invalid Date payloads instead of mangling them', () {
      expect(
        () => codec.deserialize(<String, Object?>{
          'json': <String, Object?>{'at': null},
          'meta': [
            [1, 'at'],
          ],
        }),
        throwsA(isA<RpcDecodeException>()),
      );
    });

    test('wraps an invalid RegExp pattern as RpcDecodeException', () {
      expect(
        () => codec.deserialize(<String, Object?>{
          'json': <String, Object?>{'r': '/(/'},
          'meta': [
            [5, 'r'],
          ],
        }),
        throwsA(isA<RpcDecodeException>()),
      );
    });

    test('wraps an invalid URL as RpcDecodeException', () {
      expect(
        () => codec.deserialize(<String, Object?>{
          'json': <String, Object?>{'u': 'http://[bad'},
          'meta': [
            [4, 'u'],
          ],
        }),
        throwsA(isA<RpcDecodeException>()),
      );
    });

    test('restores RegExp with mapped flags', () {
      final out = codec.deserialize(<String, Object?>{
        'json': <String, Object?>{'re': '/ab+c/gi'},
        'meta': [
          [5, 're'],
        ],
      })! as Map<String, Object?>;
      final re = out['re']! as RegExp;
      expect(re.pattern, 'ab+c');
      expect(re.isCaseSensitive, isFalse);
    });

    test('unknown handler keys leave the serialized value untouched', () {
      final out = codec.deserialize(<String, Object?>{
        'json': <String, Object?>{'x': 'raw'},
        'meta': [
          ['custom-person', 'x'],
        ],
      })! as Map<String, Object?>;
      expect(out['x'], 'raw');
    });
  });

  group('OrpcCodec non-string-keyed map round-trips', () {
    test('restores Date and BigInt entries used as keys and values', () {
      final input = <Object?, Object?>{
        DateTime.utc(2020): 'a',
        'b': BigInt.from(7),
        DateTime.utc(2021): DateTime.utc(2022),
      };
      final ser = codec.serialize(input);
      final back = codec.deserialize(<String, Object?>{
        'json': ser.json,
        'meta': ser.meta,
      });
      expect(back, <Object?, Object?>{
        DateTime.utc(2020): 'a',
        'b': BigInt.from(7),
        DateTime.utc(2021): DateTime.utc(2022),
      });
    });

    test('restores files nested in non-string-keyed maps', () {
      final file = RpcFile.bytes('a.png', Uint8List.fromList([1, 2]));
      final ser = codec.serialize(<Object?, Object?>{'k': file});
      final back = codec.deserialize(
        <String, Object?>{
          'json': ser.json,
          'meta': ser.meta,
          'maps': ser.maps,
        },
        getBlob: (i) => ser.blobs[i],
      );
      expect((back! as Map<Object?, Object?>)['k'], file);
    });
  });
}
