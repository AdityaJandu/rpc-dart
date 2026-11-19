import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:orpc_dart/orpc_dart.dart';

import 'orpc_api/api.dart';

const _bg = Color(0xFF000000);
const _fg = Color(0xFFF2F2F2);
const _dim = Color(0xFF9AA0A6);
const _border = Color(0xFF2C2C2C);
const _surface = Color(0xFF0E0E0E);
const _ok = Color(0xFF4ADE80);
const _err = Color(0xFFF87171);

/// oRPC showcase: typed queries with defined errors, multipart uploads and
/// binary downloads with progress callbacks, and live event iterators.
class OrpcShowcasePage extends StatefulWidget {
  const OrpcShowcasePage({super.key, required this.api});

  final Api api;

  @override
  State<OrpcShowcasePage> createState() => _OrpcShowcasePageState();
}

class _OrpcShowcasePageState extends State<OrpcShowcasePage> {
  String _status = 'idle';
  String? _error;
  double? _progress;
  final List<int> _ticks = [];
  StreamSubscription<StreamsTicksOutput>? _tickSub;

  @override
  void dispose() {
    unawaited(_tickSub?.cancel());
    super.dispose();
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    setState(() {
      _status = label;
      _error = null;
      _progress = null;
    });
    try {
      await action();
    } on RpcException catch (error) {
      if (mounted) {
        setState(() {
          _status = '$label: failed';
          _error = '${error.code}: ${error.message}';
        });
      }
    }
  }

  Future<void> _queryPlanet() => _run('query planet', () async {
        final planet =
            await widget.api.planet.find.query(const PlanetFindInput(id: 1));
        if (mounted) {
          setState(() => _status =
              'planet ${planet.id}: ${planet.name} (mass ${planet.mass})');
        }
      });

  Future<void> _upload() => _run('upload', () async {
        final bytes = Uint8List.fromList(List.filled(256 * 1024, 7));
        final receipt = await widget.api.uploads.avatar.mutate(
          UploadsAvatarInput(
            file: RpcFile.bytes('demo.png', bytes, contentType: 'image/png'),
            note: 'showcase',
          ),
          onSendProgress: (p) {
            if (mounted) setState(() => _progress = p.fraction);
          },
        );
        if (mounted) {
          setState(() => _status =
              'uploaded ${receipt.name}: ${receipt.size.toInt()} bytes');
        }
      });

  Future<void> _download() => _run('download', () async {
        final file = await widget.api.files.download.query(
          onReceiveProgress: (p) {
            if (mounted) setState(() => _progress = p.fraction);
          },
        );
        final bytes = await file.readBytes();
        if (mounted) {
          setState(() =>
              _status = 'downloaded ${file.filename}: ${bytes.length} bytes');
        }
      });

  Future<void> _stream() => _run('stream', () async {
        var total = 0;
        await for (final chunk in widget.api.files.stream.query()) {
          total += chunk.length;
        }
        if (mounted) setState(() => _status = 'streamed $total bytes');
      });

  Future<void> _startTicks() async {
    await _tickSub?.cancel();
    setState(() {
      _ticks.clear();
      _status = 'ticks: live';
      _error = null;
    });
    _tickSub = widget.api.streams.ticks
        .subscribe(const StreamsTicksInput(count: 5))
        .listen(
      (event) {
        if (mounted) setState(() => _ticks.add(event.tick.toInt()));
      },
      onError: (Object error) {
        if (mounted) setState(() => _error = '$error');
      },
      onDone: () {
        if (mounted) setState(() => _status = 'ticks: done');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _bg,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('oRPC showcase',
                style: TextStyle(color: _fg, fontSize: 22)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _button('Query planet', _queryPlanet),
                _button('Upload file', _upload),
                _button('Download file', _download),
                _button('Stream bytes', _stream),
                _button('Start ticks', _startTicks),
              ],
            ),
            const SizedBox(height: 16),
            Text(_status, style: const TextStyle(color: _fg)),
            if (_progress != null) ...[
              const SizedBox(height: 8),
              Text('progress: ${(_progress! * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(color: _dim)),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: _err)),
            ],
            if (_ticks.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('ticks: ${_ticks.join(', ')}',
                  style: const TextStyle(color: _ok)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _button(String label, Future<void> Function() onPressed) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: _surface,
          border: Border.all(color: _border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label, style: const TextStyle(color: _fg)),
      ),
    );
  }
}
