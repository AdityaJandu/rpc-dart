import 'dart:async';
import 'dart:typed_data';

/// A file or binary payload crossing the wire.
///
/// Buffered sources ([RpcFile.bytes]) work on every transport; streaming
/// sources ([RpcFile.stream]) require the oRPC multipart transport.
final class RpcFile {
  RpcFile._(
      this.filename, this.contentType, this.length, this._bytes, this._stream);

  /// Creates a file from in-memory bytes.
  factory RpcFile.bytes(String filename, Uint8List bytes,
          {String? contentType}) =>
      RpcFile._(filename, contentType, bytes.length, bytes, null);

  /// Creates a file from a chunked byte stream with an optional known [length].
  factory RpcFile.stream(String filename, Stream<Uint8List> stream,
          {int? length, String? contentType}) =>
      RpcFile._(filename, contentType, length, null, stream);

  /// The file name reported to the server (multipart filename / Content-Disposition).
  final String filename;

  /// MIME type, when known.
  final String? contentType;

  /// Total byte length, when known.
  final int? length;

  final Uint8List? _bytes;
  final Stream<Uint8List>? _stream;

  /// The buffered payload, when this file was created from bytes.
  Uint8List? get bufferedBytes => _bytes;

  /// Collects the full payload into memory.
  Future<Uint8List> readBytes() async {
    final bytes = _bytes;
    if (bytes != null) return bytes;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in _stream!) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Opens the payload as a chunked byte stream.
  Stream<Uint8List> openStream() {
    final bytes = _bytes;
    if (bytes != null) return Stream<Uint8List>.value(bytes);
    return _stream!;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! RpcFile) return false;
    if (filename != other.filename ||
        contentType != other.contentType ||
        length != other.length) {
      return false;
    }
    final a = _bytes;
    final b = other._bytes;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final bytes = _bytes;
    var hash = Object.hash(filename, contentType, length);
    if (bytes != null) {
      for (final byte in bytes) {
        hash = 0x1fffffff & (hash + byte);
        hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
        hash ^= hash >> 6;
      }
    }
    return hash;
  }

  @override
  String toString() =>
      'RpcFile($filename, ${length ?? '?'} bytes, ${contentType ?? 'unknown'})';
}

/// Byte-progress snapshot for upload and download callbacks.
final class RpcTransferProgress {
  /// Creates a progress snapshot.
  const RpcTransferProgress(this.transferredBytes, {this.totalBytes});

  /// Bytes transferred so far.
  final int transferredBytes;

  /// Total expected bytes, when known (Content-Length or summed file sizes).
  final int? totalBytes;

  /// Completion fraction in `[0, 1]`, or null when the total is unknown.
  double? get fraction {
    final total = totalBytes;
    if (total == null || total == 0) return null;
    return transferredBytes / total;
  }

  @override
  bool operator ==(Object other) =>
      other is RpcTransferProgress &&
      transferredBytes == other.transferredBytes &&
      totalBytes == other.totalBytes;

  @override
  int get hashCode => Object.hash(transferredBytes, totalBytes);

  @override
  String toString() =>
      'RpcTransferProgress($transferredBytes/${totalBytes ?? '?'})';
}

/// A streaming binary response body.
typedef RpcByteStream = Stream<Uint8List>;

/// Progress callback signature for request-context transfer hooks.
typedef RpcProgressCallback = void Function(RpcTransferProgress progress);
