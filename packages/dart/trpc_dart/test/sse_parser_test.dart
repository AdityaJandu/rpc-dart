import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:trpc_dart/src/sse_parser.dart';

void main() {
  group('SseParser', () {
    test('parses standard id/event/data frames', () async {
      final parser = SseParser();
      final frames = await parser
          .parse(_chunkStream([
            'event: connected\ndata: {}\n\n',
            'id: 7\ndata: {"json":{"tick":1}}\n\n',
          ]))
          .toList();
      expect(frames, hasLength(2));
      expect(frames[0].event, 'connected');
      expect(frames[0].data, '{}');
      expect(frames[0].id, isNull);
      expect(frames[1].id, '7');
      expect(frames[1].data, '{"json":{"tick":1}}');
      expect(frames[1].event, isNull);
    });

    test('reassembles frames split across 1-byte chunks', () async {
      final parser = SseParser();
      final payload = 'id: 3\ndata: hello\n\ndata: next\n\n';
      final controller = StreamController<List<int>>();
      final done = parser.parse(controller.stream).toList();
      for (final byte in utf8.encode(payload)) {
        controller.add([byte]);
      }
      await controller.close();
      final frames = await done;
      expect(frames, hasLength(2));
      expect(frames[0].id, '3');
      expect(frames[0].data, 'hello');
      expect(frames[1].data, 'next');
    });

    test('reassembles multi-byte UTF-8 split mid-codepoint', () async {
      final parser = SseParser();
      final payload = 'data: rocket-🚀-launch\n\n';
      final bytes = utf8.encode(payload);
      // The emoji starts after "data: rocket-"; split inside its 4 bytes.
      final emojiStart = utf8.encode('data: rocket-').length;
      final controller = StreamController<List<int>>();
      final done = parser.parse(controller.stream).toList();
      controller.add(bytes.sublist(0, emojiStart + 2));
      controller.add(bytes.sublist(emojiStart + 2));
      await controller.close();
      final frames = await done;
      expect(frames.single.data, 'rocket-🚀-launch');
    });

    test('handles multi-line data payloads joined with newlines', () async {
      final parser = SseParser();
      final frames = await parser
          .parse(_chunkStream([
            'data: line-one\ndata: line-two\n\n',
          ]))
          .toList();
      expect(frames.single.data, 'line-one\nline-two');
    });

    test('collects :ping comments but still frames the data event', () async {
      final parser = SseParser();
      final frames = await parser
          .parse(_chunkStream([
            ':ping\n\n',
            ': keep-alive\n',
            'data: value\n\n',
          ]))
          .toList();
      // Comment-only frames still dispatch on the blank line (SSE spec).
      expect(frames, hasLength(2));
      expect(frames[0].comments, contains('ping'));
      expect(frames[0].data, isEmpty);
      expect(frames[1].comments, contains('keep-alive'));
      expect(frames[1].data, 'value');
    });

    test('parses event: serialized-error and event: return frames', () async {
      final parser = SseParser();
      final frames = await parser
          .parse(_chunkStream([
            'event: serialized-error\ndata: {"json":{"code":401}}\n\n',
            'event: return\ndata: \n\n',
          ]))
          .toList();
      expect(frames[0].event, 'serialized-error');
      expect(frames[1].event, 'return');
    });

    test('parses retry: reconnection hint into the frame', () async {
      final parser = SseParser();
      final frames = await parser
          .parse(_chunkStream([
            'retry: 3000\n\n',
            'id: 1\ndata: hello\n\n',
          ]))
          .toList();
      expect(frames, hasLength(2));
      expect(frames[0].retry, 3000);
      expect(frames[1].retry, isNull);
    });

    test('ignores non-numeric retry: values per the SSE spec', () async {
      final parser = SseParser();
      final frames = await parser
          .parse(_chunkStream([
            'retry: abc\ndata: hello\n\n',
            'retry: 12x\ndata: world\n\n',
          ]))
          .toList();
      expect(frames, hasLength(2));
      expect(frames[0].retry, isNull);
      expect(frames[0].data, 'hello');
      expect(frames[1].retry, isNull);
      expect(frames[1].data, 'world');
    });

    test('treats lone CR variants as line separators, frames on blank lines',
        () async {
      final parser = SseParser();
      // CRLF, lone CR, and LF all end lines; only the blank line dispatches.
      final frames = await parser
          .parse(_chunkStream([
            'data: crlf\r\ndata: cr\r\rdata: done\n\n',
          ]))
          .toList();
      expect(frames, hasLength(2));
      expect(frames[0].data, 'crlf\ncr'); // two data lines, one frame
      expect(frames[1].data, 'done');
    });
  });
}

Stream<List<int>> _chunkStream(List<String> chunks) async* {
  for (final chunk in chunks) {
    yield utf8.encode(chunk);
  }
}
