# Changelog

## 0.3.0

- Binary emission: `Bytes` fields decode through `RpcJson.asBytes`, `File` fields through `RpcJson.asFile`; root-binary unary procedures emit direct `Uint8List` / `RpcFile` signatures, and `ByteStream` outputs emit streaming methods (`RpcByteStream`) with zero `as` casts.
- Unary methods gain optional `onSendProgress` / `onReceiveProgress` callbacks folded into the call context via `RpcCallContext.withProgress`.
- Typed oRPC error maps emit as sealed Dart error models with per-code variants.
- `api.dart` documents protocol-aware client construction (`OrpcLink` for oRPC, `HttpBatchLink` for tRPC).
- Generator version now reads the package version (no drift).
- Synchronized v0.3.0 lockstep release.


## 0.2.0

- Emits `.subscribe(...)` methods on subscription procedures returning `Stream<T>` with zero-cast stream-item decoding (model `fromJson` closures and `RpcJson` tearoffs for primitives).
- Generated input models imported for with-input subscriptions; `dart format`-clean output.
- Emits bindings stamped with generator version 0.2.0.

## 0.1.4

- Emits bindings stamped with generator version 0.1.4.
- Synchronized v0.1.4 lockstep release with the tsconfig-independent extractor.

## 0.1.3

- Emits bindings stamped with generator version 0.1.3.
- Package README documentation with absolute links for registry viewing.

## 0.1.2

- Idempotent OIDC release pipeline and lockstep v0.1.2 package release.

## 0.1.1

- Align repository metadata and packaging rules for automated OIDC publishing.

## 0.1.0

- Initial release.
