import { createHash } from 'node:crypto';

/**
 * Canonical serialization: compact JSON with recursively sorted object keys.
 * Determinism of this function is load-bearing for watch/check/diff (the IR
 * hash is computed over its output). Changing it is a major IR version bump.
 */
export function stableStringify(value: unknown): string {
  return writeValue(value);
}

function writeValue(value: unknown): string {
  if (value === null) return 'null';
  switch (typeof value) {
    case 'string':
      return JSON.stringify(value);
    case 'number':
      return Number.isFinite(value) ? String(value) : 'null';
    case 'boolean':
      return value ? 'true' : 'false';
    case 'bigint':
      return value.toString();
  }
  if (Array.isArray(value)) {
    return `[${value.map(writeValue).join(',')}]`;
  }
  if (typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>).filter(
      ([, v]) => v !== undefined,
    );
    entries.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${writeValue(v)}`).join(',')}}`;
  }
  return 'null'; // undefined / functions must never reach the IR
}

export function sha256Hex(input: string): string {
  return createHash('sha256').update(input).digest('hex');
}

const HASH_INPUT_KEYS = ['protocol', 'tree', 'procedures', 'types'] as const;

export function computeIrHash(ir: Record<string, unknown>): string {
  const input: Record<string, unknown> = {};
  for (const key of HASH_INPUT_KEYS) {
    input[key] = ir[key];
  }
  return `sha256-${sha256Hex(stableStringify(input))}`;
}
