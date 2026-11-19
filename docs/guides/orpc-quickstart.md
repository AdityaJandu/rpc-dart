# oRPC quickstart

rpc-dart extracts [oRPC](https://orpc.dev) contracts and routers into the same
Contract IR used for tRPC, and generates the same zero-cast Dart bindings. The
runtime transport is `OrpcLink`, wire-compatible with `RPCHandler` /
`RPCLink` from `@orpc/server` and `@orpc/client` (pinned and tested against
**1.16.3**, which is past the CVE-2026-28794 fix in 1.13.6).

## Server: contract-first or router-first

Both shapes extract. Contract-first keeps the API description separate from
the implementation:

```ts
import { oc, eventIterator } from '@orpc/contract';
import { implement } from '@orpc/server';
import { z } from 'zod';

const planet = z.object({ id: z.number(), name: z.string(), discoveredAt: z.date() });

export const contract = oc.router({
  planet: oc.router({
    find: oc.route({ method: 'GET' })
      .input(z.object({ id: z.number() }))
      .output(planet)
      .errors({ NOT_FOUND: { data: z.object({ id: z.number() }) } }),
    watch: oc.input(z.object({ id: z.number() }))
      .output(eventIterator(z.object({ tick: z.number() }))),
  }),
});

const impl = implement(contract);
export const appRouter = impl.router({
  planet: {
    find: impl.planet.find.handler(({ input, errors }) => {
      if (input.id !== 1) throw errors.NOT_FOUND({ data: { id: input.id } });
      return { id: 1, name: 'Earth', discoveredAt: new Date() };
    }),
    watch: impl.planet.watch.handler(async function* ({ input }) {
      yield { tick: input.id };
    }),
  },
});
```

Router-first (`os.handler(...)`) works too: output types are inferred from the
handler return value when `.output()` is omitted, and async-generator outputs
become subscriptions. Any Standard Schema v1 library works — Zod, Valibot,
ArkType, or oRPC's `type<T>()`.

Serve it with Fastify:

```ts
import Fastify from 'fastify';
import { RPCHandler } from '@orpc/server/fastify';
import { appRouter } from './router';

const app = Fastify();
// Leave multipart bodies unparsed so oRPC reads the raw stream itself.
app.addContentTypeParser('multipart/form-data', (_req, _payload, done) => done(null, undefined));
const handler = new RPCHandler(appRouter);
app.route({
  method: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
  url: '/rpc/*',
  handler: async (req, reply) => {
    const { matched } = await handler.handle(req, reply, { prefix: '/rpc', context: {} });
    if (!matched) reply.code(404).send({ error: 'no procedure matched' });
  },
});
```

## Generate

Point the CLI at the contract or router export — `adapter: 'auto'` (the
default) detects oRPC by probing the export's `~orpc` shape:

```ts
// rpc-dart.config.ts
import { defineConfig } from 'rpc-dart';

export default defineConfig({
  entry: 'src/router.ts',
  exportName: 'appRouter', // or the contract export
  adapter: 'auto',         // 'trpc' | 'orpc' | 'auto'
  dart: { outDir: '../flutter-app/lib/src/api' },
});
```

```bash
npx rpc-dart generate
```

The generated `api.dart` documents the oRPC client construction. Procedure
kinds map as: `eventIterator` output → subscription, `route({ method: 'GET' })`
→ query (cacheable, sent as GET `?data=` when the URL fits), everything else →
mutation. `.route()` metadata is informational for the RPC wire — oRPC always
routes by slash-delimited procedure path (`planet.find` → `/rpc/planet/find`).

## Install the runtime

oRPC bindings import the `orpc_dart` facade, which re-exports the shared
protocol-agnostic runtime and hides tRPC-only transports (HTTP batching,
SuperJSON, WebSocket). Add it to `pubspec.yaml`:

```yaml
dependencies:
  orpc_dart: ^0.3.0          # pure Dart oRPC runtime (web-safe, no Flutter required)
  orpc_flutter: ^0.3.0       # optional Flutter bridge: orpc_dart + ValueListenable
```

`orpc_flutter` re-exports `orpc_dart` plus the `trpc_flutter` `ValueListenable`
bridge, so Flutter widgets can import `package:orpc_flutter/orpc_flutter.dart`
alone.

## Client

```dart
import 'package:orpc_dart/orpc_dart.dart';
import 'src/api/api.dart';

final endpoint = Uri.parse('https://api.example.com/rpc');
final client = RpcClient(
  endpoint: endpoint,
  links: [
    ContextLink(),
    AuthLink(getHeaders: () async => {'authorization': 'Bearer $token'}),
    RetryLink(),
    OrpcLink(endpoint: endpoint),
  ],
);
final api = Api(client);

final planet = await api.planet.find.query(const PlanetFindInput(id: 1));
// watch reuses PlanetFindInput: its input shape matches find, and the
// generator dedups identical shapes into one model.
final sub = api.planet.watch.subscribe(const PlanetFindInput(id: 1));
```

All middleware links compose unchanged: `AuthLink` refreshes on the typed
`RpcUnauthorizedException` that `OrpcLink` produces from oRPC's `UNAUTHORIZED`
error, `RetryLink` retries 5xx/network failures, and subscription reconnects
resume with the latest `last-event-id`.

## Errors

`.errors({...})` maps extract as sealed Dart error models (one variant per
code, with typed `data`). On the wire, `ORPCError` payloads
(`{defined, code, status, message, data}`) map onto the existing typed
exception hierarchy — `RpcNotFoundException`, `RpcConflictException`, etc. —
with `defined: true` for declared errors and the declared HTTP status (custom
codes default to 500 unless `.errors({ CODE: { status: ... } })` sets one).

```dart
final result = await api.planet.find.safeQuery(const PlanetFindInput(id: 999));
switch (result) {
  case RpcSuccess(:final data):
    print(data.name);
  case RpcFailure(:final error):
    if (error is RpcNotFoundException && error.defined) {
      print('missing planet ${error.data?['id']}');
    }
}
```

### Typed error decoding with `fromException`

Every generated `.errors()` union also exposes a static
`fromException(RpcException error)` helper. It returns `null` for non-defined
errors (network, transport, or undeclared server errors). For defined errors
it decodes the matching variant — or the `Unknown` variant when the code is
not one of the declared ones. Variant `data` is nullable (`T?`), so a missing
payload decodes to `null` instead of throwing.

```dart
try {
  await api.planet.find.query(const PlanetFindInput(id: 999));
} on RpcException catch (e) {
  switch (PlanetFindError.fromException(e)) {
    case PlanetFindErrorNOTFOUND(:final data):
      print(data?.id);
    case null:
      print(e.code);
    default:
      break;
  }
}
```

`PlanetFindErrorNOTFOUND.data` is the typed `PlanetFindInput?` model, so
`data?.id` is a plain `double?` — no map indexing, no casts. The `null` case
covers undefined errors, where you fall back to the raw `RpcException.code`.

## Wire notes (1.16.3)

- Envelopes are `{json, meta}` with **numeric** meta tags (`0` bigint, `1`
  date, `2` nan, `3` undefined, `4` url, `5` regexp, `6` set, `7` map).
  `OrpcLink` also decodes the string tags used by oRPC 2.x.
- `Infinity` is lossy on the 1.x wire (plain `null`); Dart `double.infinity`
  round-trips as null against 1.x servers.
- File inputs/outputs ride `multipart/form-data` with the `maps` descriptors
  inside the `data` JSON field; root-level files use an empty path (`[[]]`).
- `ReadableStream<Uint8Array>` outputs stream as binary with no content-type
  header; `OrpcLink` surfaces them as `RpcByteStream`.
- Event iterators stream as SSE `message` / `done` / `error` frames with
  keepalive comments; `withEventMeta(value, {id})` provides resume ids.

See [File & binary transfers](file-transfers.md) for uploads, downloads, and
progress callbacks.