/// Pure Dart runtime for oRPC clients: the [RpcClient] link pipeline, the
/// [OrpcLink] transport (slash-routed RPC, `{json, meta}` envelopes, indexed
/// multipart file maps, raw/octet-stream downloads, and SSE event iterators),
/// binary transfers ([RpcFile]), typed oRPC errors ([RpcException.fromOrpcWire]),
/// and the state-agnostic query cache.
///
/// This is a thin facade over the `trpc_dart` engine that re-exports only the
/// protocol-agnostic and oRPC surface. tRPC-only transports (HTTP batching,
/// SuperJSON, WebSocket) are intentionally not re-exported. Generated oRPC
/// bindings import this library.
library;

export 'package:trpc_dart/trpc_dart.dart'
    hide
        HttpBatchLink,
        HttpSubscriptionLink,
        RpcTransformer,
        RpcWebSocket,
        RpcWebSocketConnector,
        SseFrame,
        SseParser,
        WsSubscriptionLink,
        applyAnnotation,
        applyCustomAnnotation,
        applyMeta,
        applyTree,
        encodeNode,
        jsonEncodeTree,
        superjsonDecode,
        superjsonEncode,
        unwrapEnvelope;
