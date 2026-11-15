# Type mapping

The complete TypeScript → Dart mapping, the `z.input` vs `z.output` split, optionality, unions, enums, and diagnostics.

← Previous: How it works | Next: Links and auth →

## Mapping table

| TypeScript / Zod | Contract | Dart |
|---|---|---|
| `string` | string | `String` |
| `number` / `z.number()` | number | `double` |
| `z.int()` | number (int) | `int` |
| `boolean` | boolean | `bool` |
| `Date` / `z.date()` | Date | `DateTime` |
| `bigint` / `z.bigint()` | BigInt | `BigInt` |
| `z.enum([...])` / `'a' \| 'b'` | enum | enhanced enum + `$unknown` |
| numeric literals `1 \| 2` | enum | enhanced enum + `$unknown` (numeric raw) |
| object shape | object | immutable class |
| `z.discriminatedUnion(...)` | discriminatedUnion | sealed class + `$Unknown` variant |
| `T[]`, `ReadonlyArray<T>` | list | `List<T>` |
| `Set<T>` / `z.set(T)` | set | `Set<T>` |
| `Record<string, T>` / `z.record(z.string(), T)` | record | `Map<String, T>` |
| `Map<K, V>` | record | `Map<K, V>` |
| `[A, B]` tuple | tuple | Dart positional record `(A, B)` |
| `z.any()` / `unknown` | unknown | `JsonValue` (default) / `dynamic` (opt-in) |
| `z.string().brand<'X'>()` | string | `String` (unwrapped) |
| Function / Symbol / Promise | — | diagnostic (never emitted) |

## `z.input` drives wire input, `z.output` drives responses

Zod transforms change the shape between the wire and the resolver, so every procedure gets **two** extracted types:

```typescript
const UpdateUserInput = z.object({
  name: z.string().optional(),
  promoCode: z.string().transform((s) => s.trim().toUpperCase()),  // wire: string, resolver: string (trimmed)
});
```

The generated `UserUpdateInput` model carries the **wire** shape (what `z.input` infers) — sending it over the wire always validates server-side. `.transform()`, `.default()`, and `.coerce()` never leak into input models; `.prefault()` semantics are asserted by the conformance fixtures.

## Optionality: absent vs null vs value

| optional | nullable | Dart | JSON behavior |
|---|---|---|---|
| ✗ | ✗ | `T` (required) | always written |
| ✗ | ✓ | `T?` (required) | written, may be null |
| ✓ | ✗ | `T?` (optional) | omitted when null |
| ✓ | ✓ | `RpcOpt<T>?` | three-state wrapper |

`RpcOpt<T>` distinguishes exactly what PATCH endpoints need:

```dart
UserUpdateInput(name: RpcPresent('Ada'))    // {"name": "Ada"}
const UserUpdateInput(nickname: RpcNull())  // {"nickname": null}
const UserUpdateInput(nickname: RpcAbsent())// key omitted — server keeps old value
```

## Unions and enums

- **Discriminated unions** (`z.discriminatedUnion('kind', [...])`) emit a Dart 3 `sealed class` with one final subclass per variant, exhaustive pattern matching, and a `$Unknown` subclass that preserves unrecognized raw payloads.
- **Literal unions** (`'draft' | 'published'`) emit enhanced enums with an `$unknown` sentinel; server-side enum additions decode to `$unknown` instead of crashing older builds. Writing `$unknown` back throws a typed exception instead of sending garbage.
- **Non-discriminated object unions** produce a diagnostic (add a literal tag field server-side, or set `unionPolicy`).

## Diagnostics

Unserializable types never silently emit `dynamic`. The CLI emits structured diagnostics with a stable code, the procedure path, exact file/line/column, and a remediation hint:

| Code | Trigger |
|---|---|
| RPCDART0201 | unserializable type (Function, Symbol, Promise, class instance) |
| RPCDART0202 | non-discriminated object union |
| RPCDART0203 | unmappable key type |
| RPCDART0105 | harness type-check failure (fix the TypeScript error) |

Policies (configurable per project): `error` (default — generation fails), `warn-dynamic` (only the offending field is downgraded to `JsonValue` and a warning is recorded in the manifest), `skip-procedure` (procedure omitted, recorded). See [Troubleshooting](../reference/troubleshooting.md).

← Previous: How it works | Next: Links and auth →
