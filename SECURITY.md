# Security Policy

## Reporting a vulnerability

Do **not** open a public issue for security vulnerabilities. Email security@rpc-dart.dev with:

1. A description of the vulnerability and its impact.
2. Reproduction steps or a minimal proof of concept.
3. Affected versions.

You will receive an acknowledgment within 48 hours. We aim to release a fix within 90 days for high-severity issues and will credit reporters in the release notes unless anonymity is requested.

## Scope

- `rpc-dart` CLI (code generation, config loading, child-process isolation)
- `trpc_dart` / `trpc_flutter` runtime (transport, decoding, credential handling)

## Security model notes

- Generated bindings contain no secrets; all credentials flow through `AuthLink` / `RpcCallContext` at runtime.
- Log redaction of secret headers is applied inside `LoggingLink` before any sink sees the data.
- The server is authoritative: client-side metadata (e.g. `access: 'authenticated'`) is advisory only.
- The CLI imports your router module in-process for metadata probing; disable via the probe-off option if your workspace policy forbids in-process evaluation.

## Supported versions

The latest release line receives security fixes. Publish a lockfile pin for production apps.
