import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:trpc_dart/trpc_dart.dart';
import 'package:trpc_flutter/trpc_flutter.dart';

import 'src/api/api.dart';

/// Composition root: one client, one generated [Api].
final client = RpcClient(
  endpoint: Uri.parse('http://127.0.0.1:8787/trpc'),
  transformer: RpcTransformer.superjson,
  defaultHeaders: const {'x-app': 'showcase'},
  links: [
    LoggingLink(
        onEvent: (event) => debugPrint(
            '[rpc] ${event.event} ${event.path} ${event.durationMs}ms')),
    AuthLink(
      getHeaders: () async => {'authorization': 'Bearer demo-token'},
      onUnauthorized: () async {
        // single-flight refresh hook; demo token never expires
        return null;
      },
    ),
    ContextLink(dynamicHeaders: () async => {'x-app-version': '1.0.0'}),
    RetryLink(policy: const RpcRetryPolicy(maxAttempts: 2)),
    HttpBatchLink(endpoint: Uri.parse('http://127.0.0.1:8787/trpc')),
  ],
);

final api = Api(client);

void main() {
  runApp(const ShowcaseApp());
}

// Monochrome palette: black background, white text, dim/grey secondary.
const _bg = Color(0xFF000000);
const _fg = Color(0xFFF2F2F2);
const _dim = Color(0xFF9AA0A6);
const _border = Color(0xFF2C2C2C);
const _surface = Color(0xFF0E0E0E);
const _ok = Color(0xFF4ADE80);
const _err = Color(0xFFF87171);
const _accent = Color(0xFF60A5FA);

class ShowcaseApp extends StatelessWidget {
  const ShowcaseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      color: _bg,
      pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
          PageRouteBuilder<T>(
        settings: settings,
        pageBuilder:
            (BuildContext context, Animation<double> _, Animation<double> __) =>
                builder(context),
      ),
      home: const ShowcasePage(),
    );
  }
}

class ShowcasePage extends StatefulWidget {
  const ShowcasePage({super.key});

  @override
  State<ShowcasePage> createState() => _ShowcasePageState();
}

class _ShowcasePageState extends State<ShowcasePage> {
  // Cache-backed queries bridged to ValueListenables. Created once for the
  // lifetime of this (home) page so listeners stay attached across rebuilds.
  late final ValueListenable<RpcAsyncState<UserGetByIdOutput>> _user;
  late final ValueListenable<RpcAsyncState<HealthOutput>> _health;

  PostsListInputSort _sort = PostsListInputSort.asc;
  final List<PostsListOutputItemsItem> _posts = [];
  String? _cursor;
  bool _loadingPosts = true;
  bool _loadingMore = false;
  String? _postsError;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _user = api.user.me.listenable();
    _health = api.health.listenable();
    // Defer the first fetch until after the first frame so setState is safe.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadPosts(reset: true);
    });
  }

  Future<void> _loadPosts({bool reset = false}) async {
    if (reset) {
      setState(() {
        _posts.clear();
        _cursor = null;
        _postsError = null;
        _loadingPosts = true;
      });
    } else {
      if (_loadingMore || _loadingPosts) return;
      setState(() => _loadingMore = true);
    }

    try {
      final page = await api.posts.list.query(
        PostsListInput(sort: _sort, cursor: _cursor),
      );
      if (!mounted) return;
      setState(() {
        _posts.addAll(page.items);
        _cursor = page.nextCursor;
        _loadingPosts = false;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingPosts = false;
        _loadingMore = false;
        _postsError = '$error';
      });
    }
  }

  void _toggleSort() {
    final next = _sort == PostsListInputSort.asc
        ? PostsListInputSort.desc
        : PostsListInputSort.asc;
    setState(() => _sort = next);
    _loadPosts(reset: true);
  }

  Future<void> _setNickname(String? nickname) async {
    setState(() => _status = 'updating nickname...');
    try {
      final updated = await api.user.update.mutate(
        UserUpdateInput(
          promoCode: 'demo',
          // Present value sets it; RpcNull keeps the key but clears it (PATCH).
          nickname: nickname == null ? const RpcNull() : RpcPresent(nickname),
        ),
      );
      api.invalidate(api.user.pathKey);
      if (!mounted) return;
      setState(() {
        _status = 'saved · nickname = ${updated.nickname ?? "(cleared)"}';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = 'update failed: $error');
    }
  }

  Future<void> _refreshAll() async {
    api.invalidate(api.user.pathKey);
    await _loadPosts(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _bg,
      child: SafeArea(
        child: DefaultTextStyle(
          style: const TextStyle(color: _fg, fontSize: 15),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              const Text(
                'rpc-dart',
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
              ),
              const Text(
                'showcase',
                style: TextStyle(color: _dim, fontSize: 15),
              ),
              const SizedBox(height: 10),

              // --- Health ---
              ValueListenableBuilder<RpcAsyncState<HealthOutput>>(
                valueListenable: _health,
                builder: (context, state, _) => switch (state) {
                  RpcAsyncLoading() => const _Hint('health · checking...'),
                  RpcAsyncError(:final error) => _StatusLine(
                      'health',
                      'error',
                      _err,
                      '$error',
                    ),
                  RpcAsyncData(:final data) => _StatusLine(
                      'health',
                      data.ok ? 'ok' : 'down',
                      data.ok ? _ok : _err,
                      'GET health → ${data.ok}',
                    ),
                },
              ),

              // --- Current user ---
              const _SectionHeader('Current user'),
              ValueListenableBuilder<RpcAsyncState<UserGetByIdOutput>>(
                valueListenable: _user,
                builder: (context, state, _) => switch (state) {
                  RpcAsyncLoading() => const _Hint('loading user.me ...'),
                  RpcAsyncError(:final error) => _Hint(
                      'error: $error',
                      color: _err,
                    ),
                  RpcAsyncData(:final data) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _InfoRow('name', data.name),
                        _InfoRow('id', data.id),
                        _InfoRow(
                          'nickname',
                          data.nickname ?? '(none)',
                          valueColor: data.nickname == null ? _dim : _fg,
                        ),
                        _InfoRow('balance', data.balance.toString()),
                        _InfoRow(
                          'createdAt',
                          data.createdAt.toLocal().toString(),
                        ),
                        _InfoRow('receipt', _receiptLabel(data.receipt)),
                      ],
                    ),
                },
              ),

              // --- Actions ---
              const _SectionHeader('Actions'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _ActionButton(
                    label: 'Set nickname',
                    tint: _accent,
                    onTap: () => _setNickname('dart-dev'),
                  ),
                  _ActionButton(
                    label: 'Clear nickname',
                    onTap: () => _setNickname(null),
                  ),
                  _ActionButton(label: 'Refresh', onTap: _refreshAll),
                ],
              ),
              if (_status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _status,
                    style: const TextStyle(color: _dim, fontSize: 13),
                  ),
                ),

              // --- Posts ---
              const _SectionHeader('Posts'),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${_posts.length} loaded',
                    style: const TextStyle(color: _dim, fontSize: 13),
                  ),
                  GestureDetector(
                    onTap: _toggleSort,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        border: Border.all(color: _border),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'sort: ${_sort.raw}  ⇅',
                        style: const TextStyle(color: _fg, fontSize: 13),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              if (_postsError != null)
                _Hint('error: $_postsError', color: _err)
              else if (_posts.isEmpty && _loadingPosts)
                const _Hint('loading posts ...')
              else if (_posts.isEmpty)
                const _Hint('no posts')
              else
                ..._posts.map((post) => _PostTile(post)),

              if (_cursor != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: _ActionButton(
                    label: _loadingMore ? 'loading...' : 'Load more',
                    onTap: _loadingMore ? () {} : () => _loadPosts(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Formats the sealed receipt union into a single readable line.
String _receiptLabel(UserGetByIdOutputReceipt receipt) {
  return switch (receipt) {
    UserGetByIdOutputReceiptCard(:final last4, :final authorizedAt) =>
      'card •••• $last4 · ${authorizedAt.toLocal()}',
    UserGetByIdOutputReceiptInvoice(:final invoiceId, :final dueInDays) =>
      'invoice $invoiceId · due ${dueInDays.toStringAsFixed(0)}d',
    UserGetByIdOutputReceiptUnknown(:final raw) =>
      'unknown (${raw.keys.join(', ')})',
  };
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: _dim,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text, {this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        text,
        style: TextStyle(
          color: color ?? _dim,
          fontSize: 13,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine(this.label, this.value, this.valueColor, this.detail);

  final String label;
  final String value;
  final Color valueColor;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: valueColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(color: _dim, fontSize: 13)),
          Text(
            value,
            style: TextStyle(
              color: valueColor,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              detail,
              style: const TextStyle(color: _dim, fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value, {this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: const TextStyle(color: _dim, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: valueColor ?? _fg, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.onTap,
    this.tint,
  });

  final String label;
  final VoidCallback onTap;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _surface,
          border: Border.all(color: tint ?? _border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(color: tint ?? _fg, fontSize: 14),
        ),
      ),
    );
  }
}

class _PostTile extends StatelessWidget {
  const _PostTile(this.post);

  final PostsListOutputItemsItem post;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _surface,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  post.title,
                  style: const TextStyle(color: _fg, fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(
                  post.id,
                  style: const TextStyle(color: _dim, fontSize: 11),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              post.score.toStringAsFixed(1),
              style: const TextStyle(color: _accent, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
