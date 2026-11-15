import 'exceptions.dart';

/// Wire transformer selection; must match the server's initTRPC transformer.
enum RpcTransformer { superjson, json }

/// Decodes a transformer output envelope (`{json, meta:{values}}`) into a
/// Dart-native tree: DateTime, BigInt, Set, Uri, NaN/Infinity. Unsupported
/// annotations throw [RpcDecodeException] naming the annotation - data is
/// never silently mangled.
Object? superjsonDecode(Object? envelope) {
  if (envelope is! Map<String, Object?>) return envelope;
  if (!envelope.containsKey('json')) return envelope;
  final meta = envelope['meta'];
  final values = meta is Map<String, Object?> ? meta['values'] : null;
  final json = envelope['json'];
  if (values is Map<String, Object?>) {
    return applyMeta(json, values);
  }
  return json;
}

/// Applies a superjson `meta.values` annotation tree to a JSON tree.
///
/// superjson emits `meta.values` as a minimised tree whose keys may be flat
/// dotted paths (`"receipt.authorizedAt"`) or nested segments; both forms are
/// normalized here before application.
Object? applyMeta(Object? value, Object? annotation) {
  if (annotation is List<Object?> && annotation.isNotEmpty) {
    final kind = annotation[0];
    if (kind is! String) {
      throw RpcDecodeException('invalid superjson annotation: $annotation');
    }
    return applyAnnotation(value, kind);
  }
  if (annotation is Map<String, Object?>) {
    final nested = normalizeAnnotationTree(annotation);
    return applyTree(value, nested);
  }
  return value;
}

/// Expands flat dotted-path keys ("items.0.when") into a nested tree.
Map<String, Object?> normalizeAnnotationTree(Map<String, Object?> flat) {
  final out = <String, Object?>{};
  void place(
      List<String> segments, Object? annotation, Map<String, Object?> node) {
    if (segments.isEmpty) return;
    final head = segments.first;
    if (segments.length == 1) {
      final existing = node[head];
      if (existing is Map<String, Object?> &&
          annotation is Map<String, Object?>) {
        for (final entry in annotation.entries) {
          place([entry.key], entry.value, existing);
        }
        return;
      }
      node[head] = annotation;
      return;
    }
    final child = node[head];
    if (child is Map<String, Object?>) {
      place(segments.sublist(1), annotation, child);
      return;
    }
    final next = <String, Object?>{};
    node[head] = next;
    if (annotation is Map<String, Object?>) {
      for (final entry in annotation.entries) {
        place([entry.key], entry.value, next);
      }
    }
    place(segments.sublist(1), annotation, next);
  }

  for (final entry in flat.entries) {
    place(entry.key.split('.'), entry.value, out);
  }
  return out;
}

Object? applyTree(Object? value, Map<String, Object?> annotation) {
  if (value is Map<String, Object?>) {
    final out = Map<String, Object?>.of(value);
    for (final entry in annotation.entries) {
      final ann = entry.value;
      if (ann is List<Object?> && ann.isNotEmpty && ann[0] == 'undefined') {
        out.remove(entry.key);
        continue;
      }
      out[entry.key] = applyMeta(value[entry.key], ann);
    }
    return out;
  }
  if (value is List<Object?>) {
    final out = List<Object?>.of(value);
    for (final entry in annotation.entries) {
      final index = int.tryParse(entry.key);
      if (index == null || index >= out.length) continue;
      out[index] = applyMeta(out[index], entry.value);
    }
    return out;
  }
  return value;
}

Object? applyAnnotation(Object? value, String kind) {
  switch (kind) {
    case 'Date':
      if (value case final String v) return DateTime.parse(v);
      throw RpcDecodeException(
          'superjson Date annotation without a string value',
          expected: 'String',
          actual: value.runtimeType.toString());
    case 'bigint':
      if (value case final String v) return BigInt.parse(v);
      if (value case final int v) return BigInt.from(v);
      throw RpcDecodeException(
          'superjson bigint annotation without a numeric value',
          expected: 'BigInt',
          actual: value.runtimeType.toString());
    case 'number':
      switch (value) {
        case 'NaN':
          return double.nan;
        case 'Infinity':
          return double.infinity;
        case '-Infinity':
          return double.negativeInfinity;
        case final num v:
          return v.toDouble();
        default:
          throw RpcDecodeException(
              'superjson number annotation without a numeric value',
              expected: 'num',
              actual: value.runtimeType.toString());
      }
    case 'negativeZero':
      return -0.0;
    case 'set':
      if (value case final List<Object?> l) return l.toSet();
      throw RpcDecodeException(
          'superjson set annotation without an array value',
          expected: 'List',
          actual: value.runtimeType.toString());
    case 'map':
    case 'regexp':
      return value;
    case 'URL':
      if (value case final String v) return Uri.parse(v);
      throw RpcDecodeException(
          'superjson URL annotation without a string value',
          expected: 'String',
          actual: value.runtimeType.toString());
    case 'undefined':
      return null;
    default:
      throw RpcDecodeException(
        'unsupported superjson type annotation "$kind" at path',
      );
  }
}

class _Encoded {
  const _Encoded(this.value, this.annotation);

  final Object? value;
  final Object? annotation; // null when no special type was found
}

/// Encodes a pre-transform Dart tree into a wire envelope. DateTime stays
/// DateTime in models; this is where the wire form is produced
///.
Object? superjsonEncode(Object? tree) {
  final result = encodeNode(tree);
  final envelope = <String, Object?>{'json': result.value};
  if (result.annotation != null) {
    envelope['meta'] = <String, Object?>{'values': result.annotation};
  }
  return envelope;
}

/// Encodes a Dart tree for the plain-json transformer: special Dart types
/// become their JSON-safe forms without a meta envelope.
Object? jsonEncodeTree(Object? tree) {
  return encodeNode(tree).value;
}

_Encoded encodeNode(Object? value) {
  if (value is DateTime) {
    return _Encoded(value.toIso8601String(), const <Object?>['Date']);
  }
  if (value is BigInt) {
    return _Encoded(value.toString(), const <Object?>['bigint']);
  }
  if (value is Map<String, Object?>) {
    final out = <String, Object?>{};
    final annotations = <String, Object?>{};
    for (final entry in value.entries) {
      final child = encodeNode(entry.value);
      out[entry.key] = child.value;
      if (child.annotation != null) {
        annotations[entry.key] = child.annotation!;
      }
    }
    return _Encoded(out, annotations.isEmpty ? null : annotations);
  }
  if (value is List<Object?>) {
    final out = <Object?>[];
    final annotations = <String, Object?>{};
    for (var i = 0; i < value.length; i++) {
      final child = encodeNode(value[i]);
      out.add(child.value);
      if (child.annotation != null) {
        annotations['$i'] = child.annotation!;
      }
    }
    return _Encoded(out, annotations.isEmpty ? null : annotations);
  }
  return _Encoded(value, null);
}
