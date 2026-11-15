/// Core value primitives shared by generated code and the runtime.
library;

import 'exceptions.dart';

/// Marker raw value for the `$unknown` enum sentinel.
const String rpcUnknownEnumRaw = '<<rpc-dart-unknown>>';

/// Numeric marker for `$unknown` in enums whose raw values are numbers.
const num rpcUnknownEnumNumRaw = -9007199254740991;

/// Three-state optionality: key omitted, key present with null, key present
/// with a value. Used only for fields that are both optional and nullable
///.
sealed class RpcOpt<T> {
  const RpcOpt();

  T? get valueOrNull;

  /// Decodes a three-state field from a decoded JSON tree. Key absence and
  /// explicit null are distinguished via [Map.containsKey]; present values
  /// are decoded with a `Model.field` breadcrumb path.
  static RpcOpt<T> decode<T>(
    Map<String, Object?> json,
    String key, {
    required T Function(Object? value, String path) decode,
    String model = '',
  }) {
    final field = model.isEmpty ? key : '$model.$key';
    if (!json.containsKey(key)) return RpcAbsent<T>();
    final value = json[key];
    if (value == null) return RpcNull<T>();
    return RpcPresent<T>(decode(value, field));
  }
}

final class RpcAbsent<T> extends RpcOpt<T> {
  const RpcAbsent();

  @override
  T? get valueOrNull => null;

  @override
  bool operator ==(Object other) => other is RpcAbsent<T>;

  @override
  int get hashCode => Object.hash('RpcAbsent', T.toString());
}

final class RpcNull<T> extends RpcOpt<T> {
  const RpcNull();

  @override
  T? get valueOrNull => null;

  @override
  bool operator ==(Object other) => other is RpcNull<T>;

  @override
  int get hashCode => Object.hash('RpcNull', T.toString());
}

final class RpcPresent<T> extends RpcOpt<T> {
  const RpcPresent(this.value);

  final T value;

  @override
  T? get valueOrNull => value;

  @override
  bool operator ==(Object other) =>
      other is RpcPresent<T> && other.value == value;

  @override
  int get hashCode => Object.hash('RpcPresent', value);
}

/// Type-safe view over arbitrary JSON (used for `unknown` fields under the
/// default `jsonValue` policy).
sealed class JsonValue {
  const JsonValue();

  factory JsonValue.fromJson(Object? json) => switch (json) {
        null => const JNull(),
        final bool b => JBool(b),
        final num n => JNum(n),
        final String s => JString(s),
        final List<Object?> l =>
          JList([for (final e in l) JsonValue.fromJson(e)]),
        final Map<String, Object?> m => JObject(
            {for (final e in m.entries) e.key: JsonValue.fromJson(e.value)}),
        _ => throw RpcDecodeException('value is not JSON-serializable'),
      };

  Object? toJson();

  /// Decoder signature for generated `RpcJson.requiredField` callbacks.
  static JsonValue fromJsonOf(Object? value, String path) =>
      JsonValue.fromJson(value);

  bool? asBoolOrNull() => this is JBool ? (this as JBool).value : null;

  num? asNumOrNull() => this is JNum ? (this as JNum).value : null;

  String? asStringOrNull() => this is JString ? (this as JString).value : null;

  List<JsonValue>? asListOrNull() =>
      this is JList ? (this as JList).value : null;

  Map<String, JsonValue>? asMapOrNull() =>
      this is JObject ? (this as JObject).value : null;
}

final class JNull extends JsonValue {
  const JNull();

  @override
  Object? toJson() => null;

  @override
  bool operator ==(Object other) => other is JNull;

  @override
  int get hashCode => 11;
}

final class JBool extends JsonValue {
  const JBool(this.value);

  final bool value;

  @override
  Object? toJson() => value;

  @override
  bool operator ==(Object other) => other is JBool && other.value == value;

  @override
  int get hashCode => Object.hash('JBool', value);
}

final class JNum extends JsonValue {
  const JNum(this.value);

  final num value;

  @override
  Object? toJson() => value;

  @override
  bool operator ==(Object other) => other is JNum && other.value == value;

  @override
  int get hashCode => Object.hash('JNum', value);
}

final class JString extends JsonValue {
  const JString(this.value);

  final String value;

  @override
  Object? toJson() => value;

  @override
  bool operator ==(Object other) => other is JString && other.value == value;

  @override
  int get hashCode => Object.hash('JString', value);
}

final class JList extends JsonValue {
  const JList(this.value);

  final List<JsonValue> value;

  @override
  Object? toJson() => [for (final e in value) e.toJson()];

  @override
  bool operator ==(Object other) =>
      other is JList && rpcDeepEquals(value, other.value);

  @override
  int get hashCode => rpcDeepHash(value);
}

final class JObject extends JsonValue {
  const JObject(this.value);

  final Map<String, JsonValue> value;

  @override
  Object? toJson() => value.map((k, v) => MapEntry(k, v.toJson()));

  @override
  bool operator ==(Object other) =>
      other is JObject && rpcDeepEquals(value, other.value);

  @override
  int get hashCode => rpcDeepHash(value);
}

/// Deep structural equality for generated models (lists, maps, values).
bool rpcDeepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List<Object?> && b is List<Object?>) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!rpcDeepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map<String, Object?> && b is Map<String, Object?>) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !rpcDeepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  return a == b;
}

/// Deep structural hash matching [rpcDeepEquals].
int rpcDeepHash(Object? value) {
  if (value is List<Object?>) {
    var h = 17;
    for (final e in value) {
      h = Object.hash(h, rpcDeepHash(e));
    }
    return h;
  }
  if (value is Map<String, Object?>) {
    var h = 31;
    final keys = value.keys.toList()..sort();
    for (final key in keys) {
      h = Object.hash(h, key, rpcDeepHash(value[key]));
    }
    return h;
  }
  return value.hashCode;
}
