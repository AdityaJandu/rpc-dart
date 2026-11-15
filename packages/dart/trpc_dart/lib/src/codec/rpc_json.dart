import 'dart:convert';

import '../exceptions.dart';

/// Zero-cast JSON decoding for generated models and the runtime wire engine.
///
/// Every reader validates with Dart 3 pattern matching and throws a
/// structured [RpcDecodeException] carrying the field breadcrumb [path], the
/// [expected] type, and the [actual] runtime type — never an unstructured VM
/// `TypeError`.
class RpcJson {
  RpcJson._();

  static String _typeName(Object? value) {
    if (value == null) return 'null';
    return value.runtimeType.toString();
  }

  static RpcDecodeException _typeError(
      String path, String expected, Object? actual) {
    return RpcDecodeException(
      'expected $expected but received ${_typeName(actual)}',
      path: path,
      expected: expected,
      actual: _typeName(actual),
    );
  }

  /// Validates that [value] is a [String] and returns it, or throws [RpcDecodeException].
  static String asString(Object? value, [String path = r'$']) {
    if (value case final String v) return v;
    throw _typeError(path, 'String', value);
  }

  /// Validates that [value] is an integer and returns it, or throws [RpcDecodeException].
  static int asInt(Object? value, [String path = r'$']) {
    switch (value) {
      case final int v:
        return v;
      case final num v when v == v.truncateToDouble():
        return v.toInt();
      default:
        throw _typeError(path, 'int', value);
    }
  }

  /// Validates that [value] is a numeric double and returns it, or throws [RpcDecodeException].
  static double asDouble(Object? value, [String path = r'$']) {
    switch (value) {
      case final num v:
        return v.toDouble();
      default:
        throw _typeError(path, 'double', value);
    }
  }

  /// Validates that [value] is a [num] and returns it, or throws [RpcDecodeException].
  static num asNum(Object? value, [String path = r'$']) {
    if (value case final num v) return v;
    throw _typeError(path, 'num', value);
  }

  /// Validates that [value] is a [bool] and returns it, or throws [RpcDecodeException].
  static bool asBool(Object? value, [String path = r'$']) {
    if (value case final bool v) return v;
    throw _typeError(path, 'bool', value);
  }

  /// Accepts a DateTime already decoded by the SuperJSON codec, or an
  /// ISO-8601 string when the plain-json transformer is in use.
  static DateTime asDateTime(Object? value, [String path = r'$']) {
    switch (value) {
      case final DateTime v:
        return v;
      case final String v:
        try {
          return DateTime.parse(v);
        } on FormatException catch (error) {
          throw RpcDecodeException(
            'invalid ISO-8601 datetime string',
            path: path,
            expected: 'DateTime',
            actual: v,
            cause: error,
          );
        }
      default:
        throw _typeError(path, 'DateTime', value);
    }
  }

  /// Accepts BigInt (SuperJSON-decoded), int, or a numeric string.
  static BigInt asBigInt(Object? value, [String path = r'$']) {
    switch (value) {
      case final BigInt v:
        return v;
      case final int v:
        return BigInt.from(v);
      case final String v:
        try {
          return BigInt.parse(v);
        } on FormatException catch (error) {
          throw RpcDecodeException(
            'invalid bigint string',
            path: path,
            expected: 'BigInt',
            actual: v,
            cause: error,
          );
        }
      default:
        throw _typeError(path, 'BigInt', value);
    }
  }

  /// Validates that [value] is a [Map] and returns it, converting keys to [String].
  static Map<String, Object?> asMap(Object? value, [String path = r'$']) {
    switch (value) {
      case final Map<String, Object?> m:
        return m;
      case final Map<Object?, Object?> m:
        return m.map((k, v) => MapEntry(k.toString(), v));
      default:
        throw _typeError(path, 'Map<String, Object?>', value);
    }
  }

  /// Decodes a [List] by running [decodeItem] on each element.
  static List<T> asList<T>(
    Object? value,
    T Function(Object? item, String itemPath) decodeItem, [
    String path = r'$',
  ]) {
    switch (value) {
      case final List<Object?> l:
        final out = <T>[];
        for (var i = 0; i < l.length; i++) {
          out.add(decodeItem(l[i], '$path[$i]'));
        }
        return out;
      default:
        throw _typeError(path, 'List<Object?>', value);
    }
  }

  /// Decodes a [Set] by running [decodeItem] on each element.
  static Set<T> asSet<T>(
    Object? value,
    T Function(Object? item, String itemPath) decodeItem, [
    String path = r'$',
  ]) {
    switch (value) {
      case final List<Object?> l:
        final out = <T>{};
        for (var i = 0; i < l.length; i++) {
          out.add(decodeItem(l[i], '$path[$i]'));
        }
        return out;
      case final Set<Object?> s:
        final out = <T>{};
        var i = 0;
        for (final item in s) {
          out.add(decodeItem(item, '$path[$i]'));
          i += 1;
        }
        return out;
      default:
        throw _typeError(path, 'Set<Object?>', value);
    }
  }

  /// Decodes a typed [Map] with [decodeKey] and [decodeVal] mappers.
  static Map<K, V> asTypedMap<K, V>(
    Object? value,
    K Function(Object? key, String keyPath) decodeKey,
    V Function(Object? val, String valPath) decodeVal, [
    String path = r'$',
  ]) {
    final map = asMap(value, path);
    final out = <K, V>{};
    map.forEach((key, val) {
      out[decodeKey(key, '$path[$key]')] = decodeVal(val, '$path.$key');
    });
    return out;
  }

  /// Validates a fixed-length array for tuple decoding.
  static List<Object?> tupleItems(Object? value, int count, String path) {
    final list = asList<Object?>(value, (item, itemPath) => item, path);
    if (list.length != count) {
      throw RpcDecodeException(
        'expected $count tuple elements but received ${list.length}',
        path: path,
        expected: 'array of length $count',
        actual: 'array of length ${list.length}',
      );
    }
    return list;
  }

  /// Decodes a required field, prefixing the breadcrumb with `Model.field`.
  static T requiredField<T>(
    Map<String, Object?> json,
    String key,
    T Function(Object? value, String path) decode, {
    String model = '',
  }) {
    final field = model.isEmpty ? key : '$model.$key';
    if (!json.containsKey(key)) {
      throw RpcDecodeException(
        'missing required field "$key"',
        path: field,
        expected: 'present',
        actual: 'absent',
      );
    }
    return decode(json[key], field);
  }

  /// Decodes an optional field: absent or null both yield null; present
  /// values are decoded with the `Model.field` breadcrumb.
  static T? optionalField<T>(
    Map<String, Object?> json,
    String key,
    T Function(Object? value, String path) decode, {
    String model = '',
  }) {
    final field = model.isEmpty ? key : '$model.$key';
    final value = json[key];
    if (value == null) return null;
    return decode(value, field);
  }

  /// Decodes arbitrary JSON text, surfacing malformed bodies as structured
  /// decode errors with the raw snippet attached.
  static Object? parse(String body, {String path = r'$'}) {
    try {
      return jsonDecode(body) as Object?;
    } on FormatException catch (error) {
      final snippet = body.length > 200 ? body.substring(0, 200) : body;
      throw RpcDecodeException(
        'non-JSON response body: $snippet',
        path: path,
        expected: 'JSON',
        actual: 'text',
        cause: error,
      );
    }
  }
}
