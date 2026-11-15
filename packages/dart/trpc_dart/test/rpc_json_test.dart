import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

void expectDecodeError(Object? value, String expectedPath, String expectedType,
    void Function() run) {
  try {
    run();
    fail('expected RpcDecodeException');
  } on RpcDecodeException catch (error) {
    expect(error.path, expectedPath);
    expect(error.expected, expectedType);
    expect(error.actual, isNotNull);
    expect(error.message, isNotEmpty);
  }
}

void main() {
  group('RpcJson primitives', () {
    test('asString accepts strings', () {
      expect(RpcJson.asString('hello'), 'hello');
    });

    test('asString throws with path on non-string', () {
      expectDecodeError(42, 'UserGetByIdOutput.id', 'String',
          () => RpcJson.asString(42, 'UserGetByIdOutput.id'));
    });

    test('asDouble coerces JSON int 10 into Dart double 10.0', () {
      expect(RpcJson.asDouble(10), 10.0);
      expect(RpcJson.asDouble(9.5), 9.5);
      expect(RpcJson.asDouble(10), isA<double>());
    });

    test('asDouble throws with path on non-numeric', () {
      expectDecodeError('nope', r'$.score', 'double',
          () => RpcJson.asDouble('nope', r'$.score'));
    });

    test('asInt accepts int and integral num, rejects fractional', () {
      expect(RpcJson.asInt(3), 3);
      expect(RpcJson.asInt(3.0), 3);
      expectDecodeError(3.5, r'$.count', 'int', () => RpcJson.asInt(3.5, r'$.count'));
    });

    test('asNum accepts any num', () {
      expect(RpcJson.asNum(2), 2);
      expect(RpcJson.asNum(2.5), 2.5);
    });

    test('asBool accepts bool only', () {
      expect(RpcJson.asBool(true), isTrue);
      expectDecodeError('true', r'$.flag', 'bool',
          () => RpcJson.asBool('true', r'$.flag'));
    });

    test('asDateTime handles decoded DateTime and ISO strings', () {
      final now = DateTime.utc(2026, 1, 15, 10);
      expect(RpcJson.asDateTime(now), now);
      expect(RpcJson.asDateTime('2026-01-15T10:00:00.000Z'), now);
    });

    test('asBigInt handles BigInt, int, numeric string', () {
      expect(RpcJson.asBigInt(BigInt.from(7)), BigInt.from(7));
      expect(RpcJson.asBigInt(7), BigInt.from(7));
      expect(RpcJson.asBigInt('4200'), BigInt.from(4200));
    });

    test('asMap validates map shape', () {
      expect(RpcJson.asMap({'a': 1}), <String, Object?>{'a': 1});
      expectDecodeError([1], r'$.payment', 'Map<String, Object?>',
          () => RpcJson.asMap([1], r'$.payment'));
    });
  });

  group('RpcJson collections', () {
    test('asList decodes items with indexed paths', () {
      final result = RpcJson.asList<int>([1, 2], // ignore: unnecessary_lambdas
        RpcJson.asInt);
      expect(result, [1, 2]);
    });

    test('asList throws with item path on bad element', () {
      expectDecodeError([1, 'x'], r'$.items[1]', 'int',
          () => RpcJson.asList<int>([1, 'x'], // ignore: unnecessary_lambdas
        RpcJson.asInt, r'$.items'));
    });

    test('asSet decodes into a set', () {
      final result = RpcJson.asSet<String>(['a', 'b'], // ignore: unnecessary_lambdas
        RpcJson.asString);
      expect(result, <String>{'a', 'b'});
    });

    test('asTypedMap decodes keys and values', () {
      final result = RpcJson.asTypedMap<String, int>(
        {'a': 1},
        RpcJson.asString,
        RpcJson.asInt,
      );
      expect(result, <String, int>{'a': 1});
    });

    test('asTypedMap throws with per-entry value path', () {
      expectDecodeError(
        {'counts': <String, Object?>{'a': 'nope'}},
        r'$.counts.a',
        'int',
        () => RpcJson.asTypedMap<String, int>(
          RpcJson.asMap({'counts': <String, Object?>{'a': 'nope'}})['counts']!,
          RpcJson.asString,
          RpcJson.asInt,
          r'$.counts',
        ),
      );
    });

    test('tupleItems validates length', () {
      expect(RpcJson.tupleItems(['a', 1], 2, r'$.origin'), ['a', 1]);
      expectDecodeError(['a'], r'$.origin', 'array of length 2',
          () => RpcJson.tupleItems(['a'], 2, r'$.origin'));
    });
  });

  group('RpcJson field readers', () {
    test('requiredField decodes present values with Model.field path', () {
      expect(
        RpcJson.requiredField({'id': 'u1'}, 'id', RpcJson.asString, model: 'UserGetByIdInput'),
        'u1',
      );
    });

    test('requiredField throws with Model.field path on missing', () {
      expectDecodeError(
        {},
        'UserGetByIdInput.id',
        'present',
        () => RpcJson.requiredField({}, 'id', RpcJson.asString, model: 'UserGetByIdInput'),
      );
    });

    test('requiredField propagates decode path with Model.field prefix', () {
      expectDecodeError(
        {'id': 42},
        'UserGetByIdInput.id',
        'String',
        () => RpcJson.requiredField({'id': 42}, 'id', RpcJson.asString, model: 'UserGetByIdInput'),
      );
    });

    test('optionalField returns null for absent and null, decodes present', () {
      expect(
        RpcJson.optionalField({'x': null}, 'x', RpcJson.asString, model: 'M'),
        isNull,
      );
      expect(
        RpcJson.optionalField({}, 'x', RpcJson.asString, model: 'M'),
        isNull,
      );
      expect(
        RpcJson.optionalField({'x': 'v'}, 'x', RpcJson.asString, model: 'M'),
        'v',
      );
    });

    test('optionalField throws with Model.field path on bad value', () {
      expectDecodeError(
        {'cursor': 5},
        'PostsListInput.cursor',
        'String',
        () => RpcJson.optionalField({'cursor': 5}, 'cursor', RpcJson.asString, model: 'PostsListInput'),
      );
    });
  });

  group('RpcOpt.decode composition', () {
    test('decode passes a Model.field path into the decoder', () {
      // The decode call throws with the composed path.
      try {
        RpcOpt.decode<String>(
          {'nickname': 42},
          'nickname',
          model: 'UserUpdateInput',
          decode: RpcJson.asString,
        );
        fail('expected RpcDecodeException');
      } on RpcDecodeException catch (error) {
        expect(error.path, 'UserUpdateInput.nickname');
      }
    });

    test('absent and null still map to RpcAbsent and RpcNull', () {
      expect(
        RpcOpt.decode<String>({}, 'nickname', model: 'M', decode: RpcJson.asString),
        isA<RpcAbsent<String>>(),
      );
      expect(
        RpcOpt.decode<String>({'nickname': null}, 'nickname', model: 'M',
            decode: RpcJson.asString),
        isA<RpcNull<String>>(),
      );
    });
  });
}
