import { createJiti } from 'jiti';

export type ProcedureKind = 'query' | 'mutation' | 'subscription';

export interface ProbePath {
  path: string;
  kind: ProcedureKind;
  meta: Record<string, unknown>;
}

export class ProbeError extends Error {}

/**
 * Runtime metadata probe: imports the router module in an isolated require
 * cache and walks the router record for procedure kinds and .meta() values.
 * Every access is feature-tested; failures throw ProbeError with context
 * rather than returning wrong kinds.
 */
export async function probeRouter(
  entryAbsolute: string,
  exportName: string,
): Promise<ProbePath[]> {
  const jiti = createJiti(entryAbsolute, { fsCache: false, moduleCache: false });
  const mod = (await jiti.import(entryAbsolute)) as Record<string, unknown>;
  const router = mod[exportName];
  if (!router || typeof router !== 'object') {
    throw new ProbeError(`export "${exportName}" not found or not a router in ${entryAbsolute}`);
  }
  const out: ProbePath[] = [];
  walk(router, [], out);
  if (out.length === 0) {
    throw new ProbeError(`no procedures discovered under "${exportName}"`);
  }
  return out.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
}

function walk(node: unknown, prefix: string[], out: ProbePath[]): void {
  const def = readDef(node);
  if (!def) return;

  // tRPC v11 routers expose a flat procedures map keyed by full dot-path.
  const flat = readFlatProcedures(def);
  if (flat) {
    for (const key of Object.keys(flat).sort()) {
      const procDef = readDef(flat[key]);
      if (!procDef) continue;
      const kind = readKind(procDef);
      if (!kind) continue;
      const meta = procDef['meta'];
      out.push({
        path: key,
        kind,
        meta: meta && typeof meta === 'object' ? (meta as Record<string, unknown>) : {},
      });
    }
    return;
  }

  // Fallback shape: nested record of routers/procedures (v10-style).
  const record = readRecord(def);
  if (record) {
    for (const key of Object.keys(record).sort()) {
      walk(record[key], [...prefix, key], out);
    }
    return;
  }

  const kind = readKind(def);
  if (!kind) return;
  const meta = def['meta'];
  out.push({
    path: prefix.join('.'),
    kind,
    meta: meta && typeof meta === 'object' ? (meta as Record<string, unknown>) : {},
  });
}

function readFlatProcedures(def: Record<string, unknown>): Record<string, unknown> | null {
  const value = def['procedures'];
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const entries = Object.entries(value as Record<string, unknown>);
  if (entries.length === 0) return null;
  // Flat map entries are procedures (leaf _defs with a kind), regardless of
  // whether the key carries a dot (top-level procedures do not).
  const isFlat = entries.every(([, v]) => {
    const procDef = readDef(v);
    return procDef !== null && readKind(procDef) !== null;
  });
  return isFlat ? (value as Record<string, unknown>) : null;
}

function readDef(node: unknown): Record<string, unknown> | null {
  const def = (node as { _def?: unknown })?._def;
  return def && typeof def === 'object' ? (def as Record<string, unknown>) : null;
}

function readRecord(def: Record<string, unknown>): Record<string, unknown> | null {
  for (const key of ['record', 'procedures']) {
    const value = def[key];
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      const keys = Object.keys(value as Record<string, unknown>);
      if (keys.length > 0) return value as Record<string, unknown>;
      if (key === 'record') return value as Record<string, unknown>; // empty router
    }
  }
  return null;
}

function readKind(def: Record<string, unknown>): ProcedureKind | null {
  const type = def['type'];
  if (type === 'query' || type === 'mutation' || type === 'subscription') return type;
  if (def['query'] !== undefined) return 'query';
  if (def['mutation'] !== undefined) return 'mutation';
  if (def['subscription'] !== undefined) return 'subscription';
  return null;
}
