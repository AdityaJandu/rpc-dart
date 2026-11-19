# Changelog

## 0.3.0

- Initial release: a thin oRPC facade over the `trpc_dart` engine.
- Re-exports `OrpcLink`, `RpcClient`, `RpcFile`, the typed `RpcException`
  hierarchy, middleware links, and the query cache.
- tRPC-only transports (HTTP batching, SuperJSON, WebSocket) are intentionally
  not re-exported.