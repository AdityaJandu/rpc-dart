import 'package:test/test.dart';
import 'package:trpc_dart/trpc_dart.dart';

void main() {
  group('RpcOpt', () {
    test('decode: absent key -> RpcAbsent', () {
      final opt = RpcOpt.decode<String>({'other': 'x'}, 'nickname',
          decode: RpcJson.asString);
      expect(opt, isA<RpcAbsent<String>>());
      expect(opt.valueOrNull, isNull);
    });

    test('decode: explicit null -> RpcNull', () {
      final opt = RpcOpt.decode<String>({'nickname': null}, 'nickname',
          decode: RpcJson.asString);
      expect(opt, isA<RpcNull<String>>());
      expect(opt.valueOrNull, isNull);
    });

    test('decode: present value -> RpcPresent with decoded value', () {
      final opt = RpcOpt.decode<String>({'nickname': 'Ada'}, 'nickname',
          decode: RpcJson.asString);
      expect(opt, isA<RpcPresent<String>>());
      expect(opt.valueOrNull, 'Ada');
    });

    test('present/null/absent are distinguishable and equal within their kind',
        () {
      expect(const RpcNull<String>(), const RpcNull<String>());
      expect(const RpcAbsent<String>(), const RpcAbsent<String>());
      expect(const RpcPresent<String>('Ada'), const RpcPresent<String>('Ada'));
      expect(const RpcPresent<String>('Ada'),
          isNot(const RpcPresent<String>('Grace')));
      expect(const RpcNull<String>(), isNot(const RpcAbsent<String>()));
    });

    test('three-state toJson semantics are representable', () {
      // The emitter relies on type discrimination for wire writes.
      const opts = <RpcOpt<String>>[
        RpcAbsent<String>(),
        RpcNull<String>(),
        RpcPresent<String>('Ada'),
      ];
      final kinds = opts.map((o) => o.runtimeType.toString()).toList();
      expect(kinds, hasLength(3));
      expect(kinds.toSet(), hasLength(3));
    });
  });

  group('JsonValue', () {
    test('fromJson/toJson round-trips a nested tree', () {
      const tree = <String, Object?>{
        'env': 'test',
        'retries': 3,
        'nested': {'flag': true, 'nothing': null},
        'list': [1, 'two', false],
      };
      final value = JsonValue.fromJson(tree);
      expect(value.toJson(), tree);
    });

    test('type accessors work without casts', () {
      final value = JsonValue.fromJson('hello');
      expect(value.asStringOrNull(), 'hello');
      expect(JsonValue.fromJson(42).asNumOrNull(), 42);
      expect(JsonValue.fromJson(null).asBoolOrNull(), isNull);
    });

    test('equality is deep', () {
      final a = JsonValue.fromJson(<Object?>[
        1,
        <String, Object?>{'x': 'y'}
      ]);
      final b = JsonValue.fromJson(<Object?>[
        1,
        <String, Object?>{'x': 'y'}
      ]);
      expect(a, b);
    });
  });

  group('rpcDeepEquals / rpcDeepHash', () {
    test('deep list equality', () {
      expect(
          rpcDeepEquals(<Object?>[
            1,
            [2, 3]
          ], <Object?>[
            1,
            [2, 3]
          ]),
          isTrue);
      expect(
          rpcDeepEquals(<Object?>[
            1,
            [2, 3]
          ], <Object?>[
            1,
            [2, 4]
          ]),
          isFalse);
    });

    test('deep map equality', () {
      expect(
        rpcDeepEquals(
          <String, Object?>{
            'a': <Object?>[1]
          },
          <String, Object?>{
            'a': <Object?>[1]
          },
        ),
        isTrue,
      );
    });

    test('hash equality follows equality', () {
      final a = <Object?>[
        1,
        [2, 3]
      ];
      final b = <Object?>[
        1,
        [2, 3]
      ];
      expect(rpcDeepHash(a), rpcDeepHash(b));
    });
  });
}
