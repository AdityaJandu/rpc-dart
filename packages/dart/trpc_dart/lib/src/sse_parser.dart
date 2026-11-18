import 'dart:async';
import 'dart:convert';

/// One complete server-sent event: the collected `id`, `event`, and `data`
/// fields plus any comment lines seen before the dispatching blank line.
class SseFrame {
  const SseFrame._({
    this.id,
    this.event,
    required this.data,
    this.comments = const <String>[],
    this.retry,
  });

  /// Latest `id:` field value (empty string means the server cleared it).
  final String? id;

  /// `event:` field value, or null for default message events.
  final String? event;

  /// `data:` field values joined with `\n` (empty string for `data:` with no
  /// value).
  final String data;

  /// Comment lines (leading `:`), used for heartbeat detection.
  final List<String> comments;

  /// `retry:` reconnection hint in milliseconds, when the block carried a
  /// valid integer value; null otherwise.
  final int? retry;

  @override
  String toString() =>
      'SseFrame(id: $id, event: $event, data: $data, comments: $comments)';
}

/// Spec-compliant SSE decoder over raw byte chunks.
///
/// Handles lines and frames split across arbitrary TCP chunks and multi-byte
/// UTF-8 characters split mid-codepoint, treats `\n`, `\r\n`, and lone `\r`
/// as line separators (Dart's LineSplitter misses lone `\r`), and dispatches
/// a frame on the blank separator line.
///
/// Controller-based end to end: async* generators defer cancellation until
/// their next event, which would hang sub.cancel() against a silent server.
class SseParser {
  /// Decodes byte [chunks] into a stream of complete [SseFrame]s.
  Stream<SseFrame> parse(Stream<List<int>> chunks) {
    String? id;
    String? event;
    final data = StringBuffer();
    var hasData = false;
    final comments = <String>[];
    int? retry;

    late final StreamController<SseFrame> out;
    late final StreamSubscription<String> lines;
    out = StreamController<SseFrame>(
      onCancel: () => lines.cancel(),
    );

    void dispatch() {
      if (!hasData &&
          event == null &&
          id == null &&
          comments.isEmpty &&
          retry == null) {
        return; // stray blank line between frames
      }
      out.add(SseFrame._(
        id: id,
        event: event,
        data: data.toString(),
        comments: List<String>.of(comments),
        retry: retry,
      ));
      id = null;
      event = null;
      data.clear();
      hasData = false;
      comments.clear();
      retry = null;
    }

    void handleLine(String line) {
      if (line.isEmpty) {
        dispatch();
        return;
      }
      if (line.startsWith(':')) {
        comments.add(line.substring(1).trim());
        return;
      }
      final colon = line.indexOf(':');
      final field = colon == -1 ? line : line.substring(0, colon);
      var value = colon == -1 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'id':
          id = value;
        case 'event':
          event = value;
        case 'data':
          if (hasData) data.write('\n');
          data.write(value);
          hasData = true;
        case 'retry':
          // SSE spec: the value must be ASCII digits only; anything else is
          // ignored. The hint floors the client's next reconnect delay.
          if (value.isNotEmpty &&
              value.codeUnits.every((c) => c >= 0x30 && c <= 0x39)) {
            retry = int.parse(value);
          }
        default:
        // Unknown fields are ignored per the SSE spec.
      }
    }

    lines = _splitLines(utf8.decoder.bind(chunks)).listen(
      handleLine,
      onError: out.addError,
      onDone: out.close,
    );
    return out.stream;
  }
}

/// Splits a text stream into lines on `\n`, `\r\n`, and lone `\r`,
/// buffering partial lines across chunk boundaries.
Stream<String> _splitLines(Stream<String> text) {
  late final StreamController<String> out;
  StreamSubscription<String>? source;
  var pending = '';
  out = StreamController<String>(
    onCancel: () => source?.cancel(),
  );
  source = text.listen(
    (chunk) {
      final combined = pending + chunk;
      var start = 0;
      for (var i = 0; i < combined.length; i++) {
        final char = combined[i];
        if (char == '\n') {
          out.add(combined.substring(start, i));
          start = i + 1;
        } else if (char == '\r') {
          out.add(combined.substring(start, i));
          if (i + 1 < combined.length && combined[i + 1] == '\n') {
            i++;
          }
          start = i + 1;
        }
      }
      pending = combined.substring(start);
    },
    onError: out.addError,
    onDone: () {
      if (pending.isNotEmpty) out.add(pending);
      out.close();
    },
  );
  return out.stream;
}
