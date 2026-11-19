# File & binary transfers

rpc-dart moves files and bytes end-to-end with typed bindings, progress
callbacks, cancellation, and zero `as` casts. The primitives live in
`trpc_dart` and work on every platform pana scores (IO, web, and the four
desktop/mobile targets) — no `dart:io` in the library, no extra dependencies.

## Primitives

```dart
// Buffered file (any transport):
final avatar = RpcFile.bytes('avatar.png', bytes, contentType: 'image/png');

// Streaming file (oRPC multipart transport):
final upload = RpcFile.stream('big.bin', chunkStream, length: totalBytes);

// Progress snapshot:
RpcTransferProgress(transferredBytes, totalBytes: total); // .fraction → 0.0..1.0 or null

// Streaming download body:
typedef RpcByteStream = Stream<Uint8List>;
```

`RpcFile.toString()` renders a bounded summary
(`RpcFile(avatar.png, 204800 bytes, image/png)`). When `logPayloads: true`,
`LoggingLink` logs the `rpcSummarizePayload` form instead —
`<RpcFile: avatar.png, 204800 bytes, image/png>` — so raw bytes never reach a
sink.

## oRPC: native multipart and binary streams

Against an oRPC `RPCHandler`, transfers use the standard oRPC wire:

```dart
import 'package:orpc_dart/orpc_dart.dart';

final endpoint = Uri.parse('https://api.example.com/rpc');
final api = Api(RpcClient(endpoint: endpoint, links: [OrpcLink(endpoint: endpoint)]));

// Upload: multipart/form-data with indexed file maps, send progress.
final receipt = await api.uploads.avatar.mutate(
  UploadsAvatarInput(file: avatar, note: 'profile'),
  onSendProgress: (p) => print('sent ${p.transferredBytes}/${p.totalBytes}'),
);

// Download (File output): buffered RpcFile with receive progress.
final file = await api.files.download.query(
  onReceiveProgress: (p) => print('received ${p.fraction}'),
);

// Streaming download (ReadableStream<Uint8Array> output): chunks as they arrive.
await for (final chunk in api.files.stream.query()) {
  sink.add(chunk);
}
```

Wire details handled for you:

- Uploads switch to `multipart/form-data` when the input contains `RpcFile` /
  `Uint8List` nodes: the `data` field carries `{json, meta, maps}`, and each
  file part is named by its index (`0`, `1`, …) in `maps` order.
- Root `File` outputs arrive as multipart with an empty-path map (`[[]]`) on
  oRPC 1.x, or as raw bodies with `Content-Disposition` on 2.x; both decode to
  `RpcFile`. Nested-file outputs decode from multipart responses.
- `ReadableStream<Uint8Array>` outputs pass through as `RpcByteStream`.
- Cancellation and timeouts apply to transfers: pass
  `RpcCallContext(cancelToken: token, timeout: Duration(seconds: 30))`.
  Cancelling mid-upload or mid-download surfaces `RpcCancelledException`
  (with `token.reason` when provided).

## tRPC: the superjson binary convention

tRPC v11 has no standard multipart wire, so binary fields ride the regular
SuperJSON envelope using two `registerCustom` transformers. Register them once
on your server's superjson instance:

```ts
import superjson from 'superjson';

superjson.registerCustom<Uint8Array, string>({
  isApplicable: (v): v is Uint8Array => v instanceof Uint8Array,
  serialize: (v) => Buffer.from(v).toString('base64'),
  deserialize: (v) => new Uint8Array(Buffer.from(v, 'base64')),
  name: 'Uint8Array',
});

superjson.registerCustom<File, { name: string; type: string; data: string }>({
  isApplicable: (v): v is File => v instanceof File,
  // File outputs are upload-only: superjson serializers are synchronous and
  // File bytes are not. Return Uint8Array for downloads.
  serialize: () => { throw new Error('return Uint8Array for downloads'); },
  deserialize: (v) => new File([Buffer.from(v.data, 'base64')], v.name, { type: v.type }),
  name: 'File',
});
```

Contracts keep real types (`z.custom<Uint8Array>()`, `z.custom<File>()`), the
extractor maps them to `Bytes` / `File`, and the generated Dart methods take
`Uint8List` / `RpcFile` directly:

```dart
import 'package:trpc_dart/trpc_dart.dart';

final echoed = await api.bytes.echo.mutate(payload); // Uint8List → Uint8List
final receipt = await api.files.upload.mutate(
  FilesUploadInput(file: RpcFile.bytes('doc.bin', bytes)),
  onSendProgress: (p) => print(p.fraction),
);
```

The wire annotations are `['custom', 'Uint8Array']` (base64 string) and
`['custom', 'File']` (`{name, type, data}`), nested correctly for root and
field positions. Chunked tRPC downloads work through subscriptions yielding
`Uint8Array` over the existing SSE link.

## Progress fidelity

Callbacks count bytes as they flow through `package:http`:

- On IO (mobile/desktop/server), progress is incremental for both uploads and
  downloads.
- On web, `package:http`'s `BrowserClient` buffers request/response bodies, so
  callbacks fire in bulk at completion rather than as network progress. The
  API is identical; only the granularity differs. True web network progress
  would require an XHR/fetch transport — a possible future upgrade behind the
  existing conditional-export pattern.

`totalBytes` is null when any part length is unknown (streaming uploads
without `length`, chunked responses without `Content-Length`); `fraction` is
null in that case.

## Logging safely

```dart
LoggingLink(
  onEvent: (event) => log(event.toString()),
  logPayloads: true, // opt-in; binary nodes become size summaries
);
```

`rpcSummarizePayload` renders `RpcFile` as
`<RpcFile: avatar.png, 204800 bytes, image/png>`, `Uint8List` as
`<204800 bytes>`, and streams as `<byte stream>`, recursing through maps and
lists. A megabyte payload produces a bounded string, never a byte dump.