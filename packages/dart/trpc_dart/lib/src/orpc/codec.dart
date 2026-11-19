import 'dart:convert';
import 'dart:typed_data';

import '../binary.dart';
import '../exceptions.dart';

/// Serializer output: the JSON envelope plus extracted file parts.
final class OrpcSerialized {
  /// Creates a serialized payload.
  const OrpcSerialized({
    required this.json,
    required this.meta,
    required this.maps,
    required this.blobs,
  });

  /// JSON-safe value tree (blob positions hold `{}` placeholders).
  final Object? json;

  /// Type-restoration tuples `[tag, ...path]` (numeric tags, oRPC 1.x wire).
  final List<List<Object?>> meta;

  /// Blob path descriptors, index-aligned with [blobs]. An empty path
  /// descriptor means the blob replaces the entire payload root.
  final List<List<Object?>> maps;

  /// Extracted file parts in wire order.
  final List<RpcFile> blobs;

  /// Whether the payload must be sent as multipart/form-data.
  bool get hasFiles => blobs.isNotEmpty;

  /// The `{json, meta?}` envelope used for application/json bodies.
  Map<String, Object?> envelope() {
    if (json == null && meta.isEmpty) return <String, Object?>{};
    return <String, Object?>{
      'json': json,
      if (meta.isNotEmpty) 'meta': meta,
    };
  }

  /// The `data` form field: `{json, meta?, maps}` as a JSON string.
  String formDataField() {
    return jsonEncode(<String, Object?>{
      'json': json,
      if (meta.isNotEmpty) 'meta': meta,
      'maps': maps,
    });
  }
}

/// oRPC StandardRPCJsonSerializer wire codec (oRPC 1.x numeric meta tags).
///
/// Decoding accepts both numeric (1.x) and string (2.x) handler keys and
/// validates every `meta`/`maps` path segment against existing structure —
/// wire paths never create keys (CVE-2026-28794 class of attacks).
final class OrpcCodec {
  /// Creates a stateless codec.
  const OrpcCodec();

  static const int _tagBigInt = 0;
  static const int _tagDate = 1;
  static const int _tagNaN = 2;
  static const int _tagUndefined = 3;
  static const int _tagUrl = 4;
  static const int _tagRegExp = 5;
  static const int _tagSet = 6;
  static const int _tagMap = 7;

  static const int _maxBigIntDigits = 4300;

  /// Encodes a Dart tree (models may carry [RpcFile] / [Uint8List] nodes).
  OrpcSerialized serialize(Object? input) {
    final meta = <List<Object?>>[];
    final maps = <List<Object?>>[];
    final blobs = <RpcFile>[];
    final json = _encode(input, const <Object?>[], meta, maps, blobs);
    return OrpcSerialized(json: json, meta: meta, maps: maps, blobs: blobs);
  }

  Object? _encode(
    Object? value,
    List<Object?> path,
    List<List<Object?>> meta,
    List<List<Object?>> maps,
    List<RpcFile> blobs,
  ) {
    if (value is RpcFile) {
      maps.add(path);
      blobs.add(value);
      return <String, Object?>{};
    }
    if (value is Uint8List) {
      maps.add(path);
      blobs.add(RpcFile.bytes('blob', value));
      return <String, Object?>{};
    }
    if (value is BigInt) {
      meta.add(<Object?>[_tagBigInt, ...path]);
      return value.toString();
    }
    if (value is DateTime) {
      meta.add(<Object?>[_tagDate, ...path]);
      return value.toUtc().toIso8601String();
    }
    if (value is double && value.isNaN) {
      meta.add(<Object?>[_tagNaN, ...path]);
      return null;
    }
    // oRPC 1.x drops Infinity to plain null (JSON.stringify semantics); the
    // 2.x `infinity` handler is decode-only here for forward compatibility.
    if (value is Uri) {
      meta.add(<Object?>[_tagUrl, ...path]);
      return value.toString();
    }
    if (value is RegExp) {
      meta.add(<Object?>[_tagRegExp, ...path]);
      final flags = StringBuffer();
      if (!value.isCaseSensitive) flags.write('i');
      if (value.isMultiLine) flags.write('m');
      if (value.isDotAll) flags.write('s');
      if (value.isUnicode) flags.write('u');
      return '/${value.pattern}/$flags';
    }
    if (value is Set<Object?>) {
      final out = _encode(value.toList(), path, meta, maps, blobs);
      meta.add(<Object?>[_tagSet, ...path]);
      return out;
    }
    if (value is Map<String, Object?>) {
      final out = <String, Object?>{};
      for (final entry in value.entries) {
        out[entry.key] = _encode(
            entry.value, <Object?>[...path, entry.key], meta, maps, blobs);
      }
      return out;
    }
    if (value is Map<Object?, Object?>) {
      final entries = <Object?>[];
      var i = 0;
      for (final entry in value.entries) {
        // Index each entry so nested special types get distinct paths
        // ([...path, i, 0|1]); the map tag is applied last, after them.
        entries.add(_encode(<Object?>[entry.key, entry.value],
            <Object?>[...path, i], meta, maps, blobs));
        i++;
      }
      meta.add(<Object?>[_tagMap, ...path]);
      return entries;
    }
    if (value is List<Object?>) {
      return <Object?>[
        for (var i = 0; i < value.length; i++)
          _encode(value[i], <Object?>[...path, i], meta, maps, blobs),
      ];
    }
    return value;
  }

  /// Restores special types from an envelope. [getBlob] resolves indexed
  /// multipart parts when `maps` descriptors are present.
  Object? deserialize(
    Map<String, Object?> envelope, {
    Object? Function(int index)? getBlob,
  }) {
    var root = _deepCopy(envelope['json']);
    final maps = envelope['maps'];
    if (maps is List<Object?> && getBlob != null) {
      for (var i = 0; i < maps.length; i++) {
        final segments = _segments(maps[i], r'$.maps');
        final blob = getBlob(i);
        if (blob is! RpcFile) {
          throw RpcDecodeException(
            'multipart part $i is not a file',
            path: r'$.maps',
            expected: 'RpcFile',
            actual: blob.runtimeType.toString(),
          );
        }
        root = _setAt(root, segments, blob);
      }
    }
    final meta = envelope['meta'];
    if (meta is List<Object?>) {
      for (final entry in meta) {
        if (entry is! List<Object?> || entry.isEmpty) {
          throw RpcDecodeException('invalid meta entry: $entry',
              path: r'$.meta');
        }
        final tag = entry[0];
        final segments = _segments(entry.sublist(1), r'$.meta');
        root = _applyTag(root, tag, segments);
      }
    }
    return root;
  }

  Object? _applyTag(Object? root, Object? tag, List<Object?> segments) {
    final path = '\$.${segments.join('.')}';
    final value = _getAt(root, segments, path);
    switch (tag) {
      case _tagBigInt:
      case 'bigint':
        if (value is! String ||
            value.length > _maxBigIntDigits ||
            BigInt.tryParse(value) == null) {
          throw RpcDecodeException(
            'bigint expects a decimal string of at most $_maxBigIntDigits digits',
            path: path,
            expected: 'String',
            actual: value.runtimeType.toString(),
          );
        }
        return _setAt(root, segments, BigInt.parse(value));
      case _tagDate:
      case 'date':
        if (value is! String) {
          throw RpcDecodeException(
            'date expects an ISO-8601 string (Invalid Date cannot be represented in Dart)',
            path: path,
            expected: 'String',
            actual: value.runtimeType.toString(),
          );
        }
        try {
          return _setAt(root, segments, DateTime.parse(value));
        } on FormatException catch (error) {
          throw RpcDecodeException('invalid ISO-8601 datetime string',
              path: path, expected: 'DateTime', actual: value, cause: error);
        }
      case _tagNaN:
      case 'nan':
        if (value != null) {
          throw RpcDecodeException('nan expects null',
              path: path,
              expected: 'null',
              actual: value.runtimeType.toString());
        }
        return _setAt(root, segments, double.nan);
      case _tagUndefined:
      case 'undefined':
        return _removeAt(root, segments);
      case _tagUrl:
      case 'url':
        if (value is! String) {
          throw RpcDecodeException('url expects a string',
              path: path,
              expected: 'String',
              actual: value.runtimeType.toString());
        }
        final Uri uri;
        try {
          uri = Uri.parse(value);
        } on FormatException catch (error) {
          throw RpcDecodeException('invalid URL string',
              path: path, expected: 'Uri', actual: value, cause: error);
        }
        return _setAt(root, segments, uri);
      case _tagRegExp:
      case 'regexp':
        if (value is! String) {
          throw RpcDecodeException('regexp expects a /pattern/flags string',
              path: path,
              expected: 'String',
              actual: value.runtimeType.toString());
        }
        final match = RegExp(r'^/(.*)/([a-z]*)$').firstMatch(value);
        if (match == null) {
          throw RpcDecodeException('regexp expects a /pattern/flags string',
              path: path, expected: '/pattern/flags', actual: value);
        }
        final flags = match.group(2)!;
        final RegExp re;
        try {
          re = RegExp(
            match.group(1)!,
            caseSensitive: !flags.contains('i'),
            multiLine: flags.contains('m'),
            dotAll: flags.contains('s'),
            unicode: flags.contains('u'),
          );
        } on FormatException catch (error) {
          throw RpcDecodeException('invalid regular expression pattern',
              path: path, expected: 'RegExp', actual: value, cause: error);
        }
        return _setAt(root, segments, re);
      case _tagSet:
      case 'set':
        if (value is! List<Object?>) {
          throw RpcDecodeException('set expects an array',
              path: path,
              expected: 'List',
              actual: value.runtimeType.toString());
        }
        return _setAt(root, segments, value.toSet());
      case _tagMap:
      case 'map':
        if (value is! List<Object?>) {
          throw RpcDecodeException('map expects an entry array',
              path: path,
              expected: 'List',
              actual: value.runtimeType.toString());
        }
        final out = <Object?, Object?>{};
        for (final pair in value) {
          if (pair is! List<Object?> || pair.length != 2) {
            throw RpcDecodeException('map entries must be [key, value] pairs',
                path: path,
                expected: '[key, value]',
                actual: pair.runtimeType.toString());
          }
          out[pair[0]] = pair[1];
        }
        return _setAt(root, segments, out);
      case 'infinity':
        switch (value) {
          case 'Infinity':
            return _setAt(root, segments, double.infinity);
          case '-Infinity':
            return _setAt(root, segments, double.negativeInfinity);
          default:
            throw RpcDecodeException(
                'infinity expects "Infinity" or "-Infinity"',
                path: path,
                expected: 'String',
                actual: value.runtimeType.toString());
        }
      default:
        // Unknown handler keys stay in serialized form (oRPC parity).
        return root;
    }
  }

  List<Object?> _segments(Object? raw, String path) {
    if (raw is! List<Object?>) {
      throw RpcDecodeException('path descriptor must be an array',
          path: path, expected: 'List', actual: raw.runtimeType.toString());
    }
    for (final segment in raw) {
      if (segment is! String && segment is! int) {
        throw RpcDecodeException('path segments must be strings or ints',
            path: path,
            expected: 'String|int',
            actual: segment.runtimeType.toString());
      }
    }
    return raw;
  }

  // Wire paths are only ever walked through EXISTING structure; a missing
  // segment is a decode error, never an insertion (CVE-2026-28794).
  Object? _walk(Object? root, List<Object?> segments, String path,
      {required bool forParent}) {
    final limit = forParent ? segments.length - 1 : segments.length;
    var current = root;
    for (var i = 0; i < limit; i++) {
      final segment = segments[i];
      switch (current) {
        case final Map<String, Object?> m when segment is String:
          if (!m.containsKey(segment)) {
            throw RpcDecodeException('segment "$segment" does not exist',
                path: path, expected: 'existing key', actual: 'absent');
          }
          current = m[segment];
        case final List<Object?> l when segment is int:
          if (segment < 0 || segment >= l.length) {
            throw RpcDecodeException('index $segment out of range',
                path: path, expected: 'existing index', actual: 'absent');
          }
          current = l[segment];
        default:
          throw RpcDecodeException('segment "$segment" does not exist',
              path: path, expected: 'existing key', actual: 'absent');
      }
    }
    return current;
  }

  Object? _getAt(Object? root, List<Object?> segments, String path) {
    if (segments.isEmpty) return root;
    final parent = _walk(root, segments, path, forParent: true);
    final last = segments.last;
    switch (parent) {
      case final Map<String, Object?> m when last is String:
        if (!m.containsKey(last)) {
          throw RpcDecodeException('segment "$last" does not exist',
              path: path, expected: 'existing key', actual: 'absent');
        }
        return m[last];
      case final List<Object?> l when last is int:
        if (last < 0 || last >= l.length) {
          throw RpcDecodeException('index $last out of range',
              path: path, expected: 'existing index', actual: 'absent');
        }
        return l[last];
      default:
        throw RpcDecodeException('segment "$last" does not exist',
            path: path, expected: 'existing key', actual: 'absent');
    }
  }

  /// Returns the (possibly replaced) root: empty segments replace the root
  /// itself, matching oRPC's root-level File/Date outputs.
  Object? _setAt(Object? root, List<Object?> segments, Object? value) {
    if (segments.isEmpty) return value;
    final path = '\$.${segments.join('.')}';
    final parent = _walk(root, segments, path, forParent: true);
    final last = segments.last;
    switch (parent) {
      case final Map<String, Object?> m when last is String:
        if (!m.containsKey(last)) {
          throw RpcDecodeException('segment "$last" does not exist',
              path: path, expected: 'existing key', actual: 'absent');
        }
        m[last] = value;
      case final List<Object?> l when last is int:
        if (last < 0 || last >= l.length) {
          throw RpcDecodeException('index $last out of range',
              path: path, expected: 'existing index', actual: 'absent');
        }
        l[last] = value;
      default:
        throw RpcDecodeException('segment "$last" does not exist',
            path: path, expected: 'existing key', actual: 'absent');
    }
    return root;
  }

  Object? _removeAt(Object? root, List<Object?> segments) {
    if (segments.isEmpty) return null;
    final path = '\$.${segments.join('.')}';
    final parent = _walk(root, segments, path, forParent: true);
    final last = segments.last;
    switch (parent) {
      case final Map<String, Object?> m when last is String:
        m.remove(last);
      case final List<Object?> l when last is int:
        if (last >= 0 && last < l.length) l[last] = null;
      default:
        break;
    }
    return root;
  }

  Object? _deepCopy(Object? value) {
    if (value is Map<String, Object?>) {
      return <String, Object?>{
        for (final entry in value.entries) entry.key: _deepCopy(entry.value),
      };
    }
    if (value is Map<Object?, Object?>) {
      return <Object?, Object?>{
        for (final entry in value.entries) entry.key: _deepCopy(entry.value),
      };
    }
    if (value is List<Object?>) {
      return <Object?>[for (final item in value) _deepCopy(item)];
    }
    return value;
  }
}
