# Changelog

## 0.3.0

- Contract IR binary primitives: `Bytes` (Uint8Array/ArrayBuffer/Buffer), `File` (File/Blob), and `ByteStream` (ReadableStream<Uint8Array>) join `PrimitiveName`.
- `AssembleEntry.error` passthrough: typed error maps reach `ProcedureRecord.error` instead of being discarded.
- Shared extraction machinery now lives in core: `TypeClassifier` (with binary symbol dispatch) and the compiler host (`overlayHost`, `typeFromAlias`, `neutralizeOptions`, `resolutionKind`, `entryImportPath`, `pathAlias`) are consumed by both the tRPC and oRPC adapters.
- Synchronized v0.3.0 lockstep release.


## 0.2.0

- Contract IR procedure metadata gains `supportsLastEventId` for tracked subscriptions.
- Synchronized v0.2.0 lockstep release.

## 0.1.4

- Synchronized v0.1.4 lockstep release with the tsconfig-independent extractor.

## 0.1.3

- Package README documentation with absolute links for registry viewing.
- Synchronized v0.1.3 lockstep release.

## 0.1.2

- Idempotent OIDC release pipeline and lockstep v0.1.2 package release.

## 0.1.1

- Align repository metadata and packaging rules for automated OIDC publishing.

## 0.1.0

- Initial release.
