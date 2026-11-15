import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

void main() {
  group('SuperJSON decode', () {
    test('unwraps an envelope with Date/bigint annotations (real wire shape)',
        () {
      final envelope = <String, Object?>{
        'json': <String, Object?>{
          'id': 'u1',
          'createdAt': '2026-01-15T10:00:00.000Z',
          'balance': '123',
        },
        'meta': <String, Object?>{
          'v': 1,
          'values': <String, Object?>{
            'createdAt': <Object?>['Date'],
            'balance': <Object?>['bigint'],
          },
        },
      };
      final tree = superjsonDecode(envelope);
      final user = tree as Map<String, Object?>;
      expect(user['id'], 'u1');
      expect(user['createdAt'], DateTime.utc(2026, 1, 15, 10));
      expect(user['balance'], BigInt.from(123));
    });

    test('handles nested annotation trees and lists', () {
      final envelope = <String, Object?>{
        'json': <String, Object?>{
          'items': <Object?>[
            <String, Object?>{'when': '2026-02-01T00:00:00.000Z'},
          ],
          'inner': <String, Object?>{'big': '999'},
        },
        'meta': <String, Object?>{
          'values': <String, Object?>{
            'items': <String, Object?>{
              '0': <String, Object?>{
                'when': <Object?>['Date']
              },
            },
            'inner': <String, Object?>{
              'big': <Object?>['bigint']
            },
          },
        },
      };
      final tree = superjsonDecode(envelope) as Map<String, Object?>;
      final items = tree['items'] as List<Object?>;
      expect(
          (items[0] as Map<String, Object?>)['when'], DateTime.utc(2026, 2, 1));
      expect((tree['inner'] as Map<String, Object?>)['big'], BigInt.from(999));
    });

    test(
        'handles flat dotted-path annotations (real wire shape, nested objects)',
        () {
      final envelope = <String, Object?>{
        'json': <String, Object?>{
          'id': 'u1',
          'receipt': <String, Object?>{
            'kind': 'card',
            'authorizedAt': '2026-01-15T10:00:00.000Z'
          },
        },
        'meta': <String, Object?>{
          'v': 1,
          'values': <String, Object?>{
            'receipt.authorizedAt': <Object?>['Date'],
          },
        },
      };
      final tree = superjsonDecode(envelope) as Map<String, Object?>;
      final receipt = tree['receipt'] as Map<String, Object?>;
      expect(receipt['authorizedAt'], DateTime.utc(2026, 1, 15, 10));
    });

    test('handles dotted-path annotations into lists', () {
      final envelope = <String, Object?>{
        'json': <String, Object?>{
          'items': <Object?>[
            <String, Object?>{'when': '2026-02-01T00:00:00.000Z'},
          ],
        },
        'meta': <String, Object?>{
          'values': <String, Object?>{
            'items.0.when': <Object?>['Date'],
          },
        },
      };
      final tree = superjsonDecode(envelope) as Map<String, Object?>;
      final items = tree['items'] as List<Object?>;
      expect(
          (items[0] as Map<String, Object?>)['when'], DateTime.utc(2026, 2, 1));
    });

    test('decodes NaN/Infinity annotations', () {
      final envelope = <String, Object?>{
        'json': <String, Object?>{'x': 'NaN', 'y': 'Infinity'},
        'meta': <String, Object?>{
          'values': <String, Object?>{
            'x': <Object?>['number'],
            'y': <Object?>['number'],
          },
        },
      };
      final tree = superjsonDecode(envelope) as Map<String, Object?>;
      expect(tree['x'], isNaN);
      expect(tree['y'], double.infinity);
    });

    test('throws RpcDecodeException on unsupported annotations', () {
      final envelope = <String, Object?>{
        'json': <String, Object?>{'f': null},
        'meta': <String, Object?>{
          'values': <String, Object?>{
            'f': <Object?>['function'],
          },
        },
      };
      expect(
          () => superjsonDecode(envelope), throwsA(isA<RpcDecodeException>()));
    });
  });

  group('SuperJSON encode', () {
    test('wraps DateTime and BigInt inputs with annotations', () {
      final input = <String, Object?>{
        'when': DateTime.utc(2026, 1, 15, 10),
        'big': BigInt.from(42),
        'plain': 'x',
      };
      final envelope = superjsonEncode(input) as Map<String, Object?>;
      final json = envelope['json'] as Map<String, Object?>;
      expect(json['when'], '2026-01-15T10:00:00.000Z');
      expect(json['big'], '42');
      expect(json['plain'], 'x');
      final values = (envelope['meta'] as Map<String, Object?>)['values']
          as Map<String, Object?>;
      expect(values['when'], <Object?>['Date']);
      expect(values['big'], <Object?>['bigint']);
    });

    test('encode -> decode round-trip preserves Dart values', () {
      final input = <String, Object?>{
        'when': DateTime.utc(2026, 3, 4),
        'big': BigInt.from(7),
      };
      final decoded =
          superjsonDecode(superjsonEncode(input)) as Map<String, Object?>;
      expect(decoded['when'], DateTime.utc(2026, 3, 4));
      expect(decoded['big'], BigInt.from(7));
    });

    test('plain inputs produce a json-only envelope (no meta)', () {
      final envelope = superjsonEncode(<String, Object?>{'id': 'u1'})
          as Map<String, Object?>;
      expect(envelope['json'], <String, Object?>{'id': 'u1'});
      expect(envelope.containsKey('meta'), isFalse);
    });
  });
}
