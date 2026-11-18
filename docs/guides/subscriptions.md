# Real-time subscriptions (SSE & WebSocket)

tRPC v11 subscriptions stream events to the client. rpc-dart extracts them into
generated `.subscribe()` methods returning `Stream<T>`, and ships two wire
transports: `HttpSubscriptionLink` (Server-Sent Events, compatible with
tRPC's `httpSubscriptionLink`) and `WsSubscriptionLink` (WebSocket, compatible
with tRPC's `applyWSSHandler` / `wsLink`).

## Server: the three subscription shapes

The extractor unwraps all three tRPC v11 subscription output shapes down to
the streamed item type:

```ts
// 1. Async generator — yields plain values
onServerTick: publicProcedure.subscription(async function* () {
  while (true) {
    yield { tick: 1, timestamp: new Date(), memoryBytes: BigInt(1234) };
    await sleep(250);
  }
}),

// 2. Tracked async generator — every event carries a resumable id
onActivityFeed: publicProcedure
  .input(z.object({ lastEventId: z.string().nullish() }))
  .subscription(async function* (opts) {
    // Replay missed events, then stream live ones.
    for (const event of missedAfter(opts.input?.lastEventId)) {
      yield tracked(event.id, event);
    }
    // ... then live events
  }),

// 3. Observable (legacy, still extracted)
onPresence: publicProcedure.subscription(() =>
  observable<UserEvent>((emit) => {
    emit.next({ userId: 'u1', action: 'join' });
    return () => {};
  }),
);
```

Procedures that use `tracked()` set `supportsLastEventId: true` in the
Contract IR, and their generated input models keep the `lastEventId` field.

## Client: SplitLink + a subscription transport

Route unary calls to the batch link and subscriptions to a stream link:

```dart
final client = RpcClient(
  endpoint: Uri.parse('http://127.0.0.1:8787/trpc'),
  transformer: RpcTransformer.superjson,
  links: [
    ContextLink(dynamicHeaders: () async => {'x-app-version': '1.0.0'}),
    AuthLink(getHeaders: () async => {'authorization': 'Bearer $token'}),
    LoggingLink(onEvent: (event) => debugPrint('[rpc] ${event.event} ${event.path}')),
    SplitLink(
      unaryLink: HttpBatchLink(endpoint: endpoint),
      subscriptionLink: HttpSubscriptionLink(endpoint: endpoint), // SSE
      // or: WsSubscriptionLink(endpoint: wsEndpoint),            // WebSocket
    ),
  ],
);

// Generated bindings: Stream<StreamsOnServerTickOutput>
final ticks = api.streams.onServerTick.subscribe();
await for (final tick in ticks) {
  print('tick ${tick.tick} at ${tick.timestamp} (${tick.memoryBytes} bytes)');
}
```

### Choosing a transport

| Transport | Link | Best for |
| --- | --- | --- |
| SSE | `HttpSubscriptionLink` | Firewalls/proxies, one event direction, simplest infra |
| WebSocket | `WsSubscriptionLink` | Many concurrent subscriptions over one connection, low latency both ways |

`WsSubscriptionLink` multiplexes every `.subscribe()` over a single shared
socket and reconnects on `{"method": "reconnect"}` notifications.
`connectionParams` for auth handshakes rides the subscription options and is
re-resolved on every connect/reconnect:

```dart
WsSubscriptionLink(endpoint: Uri.parse('ws://127.0.0.1:8788/trpc'));

api.streams.onActivityFeed.subscribe(
  StreamsOnActivityFeedInput(),
  options: RpcSubscriptionOptions(
    connectionParams: () async => {'token': await readToken()},
  ),
);
```

## Resuming after drops: `tracked()` + `lastEventId`

The reconnect engine lives in the link chain. On retryable failures (network
drop, 5xx, server reconnect notification) the whole chain re-runs after
exponential backoff with jitter — so `ContextLink` re-resolves correlation
ids, `AuthLink` re-attaches fresh credentials, and the subscription resumes
from the latest tracked event id:

```dart
final stream = api.streams.onActivityFeed.subscribe(
  StreamsOnActivityFeedInput(
    lastEventId: savedId == null ? null : RpcPresent(savedId),
  ),
  options: RpcSubscriptionOptions(
    lastEventId: savedId,               // header/query resume point
    reconnectPolicy: RpcReconnectPolicy(
      maxAttempts: 10,
      initialDelay: Duration(milliseconds: 250),
      backoffMultiplier: 2,
      jitterRatio: 0.2,
    ),
    onEventId: (id) => savedId = id,    // latest resume point
  ),
);
```

Clean completions (`event: return` over SSE, `stopped` over WebSocket) close
the stream without reconnecting. Client cancellation (`CancelToken` or
`StreamSubscription.cancel()`) aborts the in-flight transport immediately and
cancels pending backoff timers.

### Single-flight auth refresh on streams

`AuthLink` intercepts `UNAUTHORIZED` stream errors, runs exactly one refresh
even when several streams fail simultaneously, and re-subscribes each stream
with the new credentials and its latest event id.

## Flutter: `RpcSubscriptionController`

```dart
final controller = RpcSubscriptionController<String>(
  streamFactory: ({lastEventId, onReconnect}) => api.streams.onActivityFeed
      .subscribe(
        StreamsOnActivityFeedInput(
          lastEventId: lastEventId == null ? null : RpcPresent(lastEventId),
        ),
        options: RpcSubscriptionOptions(
          lastEventId: lastEventId,
          onReconnect: onReconnect,
        ),
      )
      .map((event) => event.message),
  keepHistoryCount: 20,
  queryCache: client.cache,
  invalidatePrefixesOnData: [
    ['streams', 'onActivityFeed'],
  ],
)..start();

ValueListenableBuilder<RpcSubscriptionState<String>>(
  valueListenable: controller,
  builder: (context, state, _) => Text(state.data ?? 'connecting...'),
);
```

Forwarding `onReconnect` into the options lets the controller surface
`RpcSubscriptionStatus.reconnecting` while the chain re-subscribes, preserving
the last `data`, `history`, and `lastEventId` until events flow again. Every
incoming event can auto-invalidate matching query-cache prefixes, so dependent
queries refetch from live data. `pause()` / `resume()` / `restart()` control the
stream; `dispose()` cancels it.

## Backpressure and cancellation recipes

- **Bounded history:** set `keepHistoryCount` to cap the event buffer.
- **Take what you need:** `stream.take(3)` unsubscribes after the third event
  (the transport stop frame / SSE abort fires automatically).
- **Timeout an idle stream:** `stream.timeout(const Duration(seconds: 30))`
  cancels the underlying transport on timeout.
- **Reconnect a silent SSE stream:** set `idleTimeout` on `HttpSubscriptionLink`
  (or override per subscription via `RpcSubscriptionOptions.idleTimeout`). A
  stream that goes silent past the deadline — a half-open dead connection — is
  aborted and reconnected from the latest tracked id; the timer resets on every
  frame, comment, or `:ping` and is cancelled on unsubscribe. A server-sent
  `retry: <ms>` hint floors the next reconnect delay.
- **Manual cancel:** `CancelToken` (shared across calls) or
  `subscription.cancel()` — both abort the socket and any pending reconnect.

## What the wire looks like

SSE request: `GET /trpc/<path>?input=<encoded>` with
`Accept: text/event-stream`; resume with a `Last-Event-ID` header (tRPC also
accepts `lastEventId` as a query parameter and merges it into
`input.lastEventId`). Frames: `connected`, data (default `message` events with
superjson envelopes; tracked events carry `id:` lines), `ping`,
`serialized-error`, and `return` for clean completion.

WebSocket frames: `subscription` start / `subscription.stop`, and server
`started` / `data` (tracked payloads arrive as `{id, data}`) / `stopped` /
`error` responses, plus `{"id": null, "method": "reconnect"}` notifications and
`PING`/`PONG` keep-alives.
