import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:trpc_dart/src/orpc/multipart.dart';
import 'package:trpc_dart/trpc_dart.dart';

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

Uint8List body(List<Object> parts) {
  final b = BytesBuilder();
  for (final p in parts) {
    b.add(p is String ? utf8.encode(p) : p as List<int>);
  }
  return b.takeBytes();
}

void main() {
  group('parseMultipart Content-Disposition', () {
    test('parses name when filename precedes it', () {
      final parsed = parseMultipart(
          bytes('--Xb\r\nContent-Disposition: form-data; filename="a.png"; '
              'name="0"\r\nContent-Type: image/png\r\n\r\nDATA\r\n--Xb--\r\n'),
          'Xb');
      expect(parsed.files.single.name, '0');
      expect(parsed.files.single.filename, 'a.png');
    });

    test('parses name when name precedes filename', () {
      final parsed = parseMultipart(
          bytes('--Xb\r\nContent-Disposition: form-data; name="0"; '
              'filename="a.png"\r\n\r\nDATA\r\n--Xb--\r\n'),
          'Xb');
      expect(parsed.files.single.name, '0');
      expect(parsed.files.single.filename, 'a.png');
    });

    test('decodes RFC 5987 filename*', () {
      final parsed = parseMultipart(
          bytes('--Xb\r\nContent-Disposition: form-data; name="0"; '
              "filename*=UTF-8''na%C3%AFve.png\r\n\r\nDATA\r\n--Xb--\r\n"),
          'Xb');
      expect(parsed.files.single.filename, 'naïve.png');
    });

    test('parses an unquoted filename token', () {
      final parsed = parseMultipart(
          bytes('--Xb\r\nContent-Disposition: form-data; name="0"; '
              'filename=a.png\r\n\r\nDATA\r\n--Xb--\r\n'),
          'Xb');
      expect(parsed.files.single.filename, 'a.png');
    });
  });

  group('parseMultipart framing', () {
    test('parses LF-only framing', () {
      final parsed = parseMultipart(
          bytes('--Xb\nContent-Disposition: form-data; name="a"\n\nv\n'
              '--Xb--\n'),
          'Xb');
      expect(parsed.fields['a'], 'v');
    });

    test('keeps binary content with CRLF and a partial boundary intact', () {
      final bin = Uint8List.fromList([1, 13, 10, 2, 45, 45, 88, 90, 3]);
      final parsed = parseMultipart(
          body([
            '--Xb\r\nContent-Disposition: form-data; name="0"; filename="f.bin"\r\n\r\n',
            bin,
            '\r\n--Xb--\r\n',
          ]),
          'Xb');
      expect(parsed.files.single.bytes, bin);
    });

    test('does not split on a boundary substring mid-line', () {
      final evil = bytes('AB--XbCD');
      final parsed = parseMultipart(
          body([
            '--Xb\r\nContent-Disposition: form-data; name="0"; filename="f.bin"\r\n\r\n',
            evil,
            '\r\n--Xb--\r\n',
          ]),
          'Xb');
      expect(parsed.files.single.bytes, evil);
    });

    test('wraps invalid UTF-8 in a text field as RpcDecodeException', () {
      expect(
        () => parseMultipart(
            body([
              '--Xb\r\nContent-Disposition: form-data; name="a"\r\n\r\n',
              [0xff, 0xfe],
              '\r\n--Xb--\r\n',
            ]),
            'Xb'),
        throwsA(isA<RpcDecodeException>()),
      );
    });
  });
}
