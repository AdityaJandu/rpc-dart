# Changelog

## 0.3.0

- Initial release: oRPC contract (`oc`) and router (`os` / `implement()`) extraction into Contract IR.
- Standard Schema v1 input/output inference (Zod, Valibot, ArkType), handler-inferred outputs, event-iterator subscriptions, typed `.errors({...})` maps, route metadata, lazy routers, and binary primitives (`Bytes` / `File` / `ByteStream`).
- Shares the type classifier and compiler host with `@rpc-dart/trpc-adapter` through `@rpc-dart/core`.