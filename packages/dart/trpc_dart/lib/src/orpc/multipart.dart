import 'dart:convert';
import 'dart:typed_data';

import '../exceptions.dart';

/// One parsed multipart part.
final class MultipartPart {
  /// Creates a parsed part.
  const MultipartPart({
    required this.name,
    required this.filename,
    required this.contentType,
    required this.bytes,
  });

  /// Form field name from Content-Disposition.
  final String? name;

  /// File name when the part is a file upload.
  final String? filename;

  /// Part MIME type, when declared.
  final String? contentType;

  /// Raw part body.
  final Uint8List bytes;
}

/// A parsed multipart/form-data body: text fields plus file parts.
final class MultipartBody {
  /// Creates a parsed body.
  const MultipartBody({required this.fields, required this.files});

  /// Non-file parts keyed by field name.
  final Map<String, String> fields;

  /// File parts ordered by their numeric field name (oRPC indexed maps).
  final List<MultipartPart> files;
}

/// Parses a buffered multipart/form-data body against its [boundary].
///
/// Handles CRLF and LF framing, quoted and unquoted disposition parameters,
/// and RFC 5987 `filename*`. Boundary delimiters are only recognized at the
/// start of a line, so binary content that happens to contain the boundary
/// bytes mid-line is preserved verbatim.
MultipartBody parseMultipart(Uint8List body, String boundary) {
  final delimiter = utf8.encode('--$boundary');
  final segments = _split(body, delimiter);
  final fields = <String, String>{};
  final files = <MapEntry<int, MultipartPart>>[];
  // segments[0] is the preamble; each later segment is one part.
  for (var i = 1; i < segments.length; i++) {
    var segment = segments[i];
    if (segment.length >= 2 && segment[0] == 0x2d && segment[1] == 0x2d) {
      break; // closing boundary suffix '--'
    }
    segment = _stripLeadingEol(segment);
    segment = _stripTrailingEol(segment);
    final separator = _headerSeparator(segment);
    if (separator == null) {
      throw RpcDecodeException('multipart part without header separator',
          path: r'$.multipart');
    }
    final (headerEnd, contentStart) = separator;
    final headerText =
        utf8.decode(Uint8List.sublistView(segment, 0, headerEnd));
    final content = Uint8List.sublistView(segment, contentStart);
    final headers = <String, String>{};
    for (final line in headerText.split(RegExp(r'\r?\n'))) {
      final colon = line.indexOf(':');
      if (colon > 0) {
        headers[line.substring(0, colon).trim().toLowerCase()] =
            line.substring(colon + 1).trim();
      }
    }
    final disposition = headers['content-disposition'] ?? '';
    final name = _dispositionParam(disposition, 'name');
    final filename = _filename(disposition);
    final part = MultipartPart(
      name: name,
      filename: filename,
      contentType: headers['content-type'],
      bytes: content,
    );
    if (filename != null) {
      final index = int.tryParse(name ?? '') ?? files.length;
      files.add(MapEntry(index, part));
    } else if (name != null) {
      try {
        fields[name] = utf8.decode(content);
      } on FormatException catch (error) {
        throw RpcDecodeException(
            'multipart text field "$name" is not valid UTF-8',
            path: r'$.multipart',
            expected: 'UTF-8 String',
            cause: error);
      }
    }
  }
  files.sort((a, b) => a.key.compareTo(b.key));
  return MultipartBody(
    fields: fields,
    files: [for (final entry in files) entry.value],
  );
}

Uint8List _stripLeadingEol(Uint8List segment) {
  if (segment.length >= 2 && segment[0] == 0x0d && segment[1] == 0x0a) {
    return Uint8List.sublistView(segment, 2);
  }
  if (segment.isNotEmpty && segment[0] == 0x0a) {
    return Uint8List.sublistView(segment, 1);
  }
  return segment;
}

Uint8List _stripTrailingEol(Uint8List segment) {
  if (segment.length >= 2 &&
      segment[segment.length - 2] == 0x0d &&
      segment[segment.length - 1] == 0x0a) {
    return Uint8List.sublistView(segment, 0, segment.length - 2);
  }
  if (segment.isNotEmpty && segment[segment.length - 1] == 0x0a) {
    return Uint8List.sublistView(segment, 0, segment.length - 1);
  }
  return segment;
}

/// Returns (headerEnd, contentStart) for the first blank line, accepting both
/// CRLF and LF framing, or null when the part has no header separator.
(int, int)? _headerSeparator(Uint8List bytes) {
  for (var i = 0; i + 1 < bytes.length; i++) {
    if (bytes[i] == 0x0a && bytes[i + 1] == 0x0a) return (i, i + 2);
    if (i + 3 < bytes.length &&
        bytes[i] == 0x0d &&
        bytes[i + 1] == 0x0a &&
        bytes[i + 2] == 0x0d &&
        bytes[i + 3] == 0x0a) {
      return (i, i + 4);
    }
  }
  return null;
}

/// Matches a disposition parameter anchored at a parameter boundary so `name`
/// never matches the tail of `filename`. Accepts quoted and token values.
String? _dispositionParam(String disposition, String param) {
  final quoted = RegExp('(?:^|;)\\s*$param="([^"]*)"', caseSensitive: false)
      .firstMatch(disposition);
  if (quoted != null) return quoted.group(1);
  return RegExp('(?:^|;)\\s*$param=([^;\\s"]+)', caseSensitive: false)
      .firstMatch(disposition)
      ?.group(1);
}

String? _filename(String disposition) {
  final star =
      RegExp(r'(?:^|;)\s*filename\*\s*=\s*([^;]+)', caseSensitive: false)
          .firstMatch(disposition);
  if (star != null) {
    final decoded = _decodeRfc5987(star.group(1)!.trim());
    if (decoded != null) return decoded;
  }
  return _dispositionParam(disposition, 'filename');
}

/// Decodes an RFC 5987 ext-value (`charset'lang'percent-encoded`).
String? _decodeRfc5987(String value) {
  final first = value.indexOf("'");
  if (first == -1) return null;
  final second = value.indexOf("'", first + 1);
  if (second == -1) return null;
  final charset = value.substring(0, first).toLowerCase();
  final encoded = value.substring(second + 1);
  final out = <int>[];
  for (var i = 0; i < encoded.length; i++) {
    final c = encoded[i];
    if (c == '%' && i + 2 < encoded.length) {
      final hex = int.tryParse(encoded.substring(i + 1, i + 3), radix: 16);
      if (hex == null) return null;
      out.add(hex);
      i += 2;
    } else {
      out.add(c.codeUnitAt(0));
    }
  }
  return charset == 'iso-8859-1'
      ? latin1.decode(out)
      : utf8.decode(out, allowMalformed: true);
}

/// Splits on `--boundary` occurrences that start a line (body start or after a
/// LF), returning the segments between them with the delimiter bytes removed.
List<Uint8List> _split(Uint8List body, List<int> delimiter) {
  final out = <Uint8List>[];
  var start = 0;
  var i = 0;
  while (i <= body.length - delimiter.length) {
    final atLineStart = i == 0 || body[i - 1] == 0x0a;
    var matched = atLineStart;
    if (matched) {
      for (var j = 0; j < delimiter.length; j++) {
        if (body[i + j] != delimiter[j]) {
          matched = false;
          break;
        }
      }
    }
    if (matched) {
      out.add(Uint8List.sublistView(body, start, i));
      i += delimiter.length;
      start = i;
    } else {
      i++;
    }
  }
  out.add(Uint8List.sublistView(body, start));
  return out;
}
