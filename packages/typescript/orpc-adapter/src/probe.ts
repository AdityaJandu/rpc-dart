import { createJiti } from 'jiti';

export class ProbeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ProbeError';
  }
}

export interface ProbePath {
  path: string;
  kind: 'query' | 'mutation' | 'subscription';
  meta: Record<string, unknown>;
  route: { method?: string; path?: string };
  errorCodes: string[];
  inputIsEventIterator: boolean;
  contract: boolean;
}

// oRPC marks lazy routers and event-iterator schemas with module-private
// symbols; their descriptions are stable across 1.x and let the probe stay
// dependency-free (the consumer's project supplies @orpc/*).
const LAZY_DESCRIPTION = 'ORPC_LAZY_SYMBOL';
const EVENT_ITERATOR_DESCRIPTION = 'ORPC_EVENT_ITERATOR_DETAILS';

function findSymbol(obj: object, description: string): symbol | undefined {
  return Object.getOwnPropertySymbols(obj).find((s) => s.description === description);
}

function isEventIteratorSchema(schema: unknown): boolean {
  if (typeof schema !== 'object' || schema === null) return false;
  const standard = (schema as Record<string, unknown>)['~standard'];
  if (typeof standard !== 'object' || standard === null) return false;
  return findSymbol(standard, EVENT_ITERATOR_DESCRIPTION) !== undefined;
}

interface LeafDef {
  route?: { method?: string; path?: string };
  meta?: Record<string, unknown>;
  errorMap?: Record<string, unknown>;
  inputSchema?: unknown;
  outputSchema?: unknown;
  handler?: unknown;
}

function leafDef(value: object): LeafDef | null {
  const def = (value as Record<string, unknown>)['~orpc'];
  return typeof def === 'object' && def !== null ? (def as LeafDef) : null;
}

export async function probeRouter(entryAbsolute: string, exportName: string): Promise<ProbePath[]> {
  const jiti = createJiti(entryAbsolute, { fsCache: false, moduleCache: false });
  const mod = (await jiti.import(entryAbsolute)) as Record<string, unknown>;
  const root = mod[exportName];
  if (typeof root !== 'object' || root === null) {
    throw new ProbeError(`export "${exportName}" not found or not an object in ${entryAbsolute}`);
  }

  const paths: ProbePath[] = [];
  await walk(root, []);
  if (paths.length === 0) {
    throw new ProbeError(`no oRPC procedures found in export "${exportName}"`);
  }
  return paths.sort((a, b) => (a.path < b.path ? -1 : 1));

  async function walk(node: unknown, segments: string[]): Promise<void> {
    if (typeof node !== 'object' || node === null) return;
    const lazySymbol = findSymbol(node, LAZY_DESCRIPTION);
    if (lazySymbol) {
      const lazyEntry = (node as Record<symbol, { loader: () => Promise<{ default: unknown }> }>)[lazySymbol];
      if (lazyEntry) {
        const loaded = await lazyEntry.loader();
        await walk(loaded.default, segments);
      }
      return;
    }
    const def = leafDef(node);
    if (def) {
      const kind = isEventIteratorSchema(def.outputSchema)
        ? 'subscription'
        : def.route?.method === 'GET'
          ? 'query'
          : 'mutation';
      const route: ProbePath['route'] = {};
      if (def.route?.method !== undefined) route.method = def.route.method;
      if (def.route?.path !== undefined) route.path = def.route.path;
      paths.push({
        path: segments.join('.'),
        kind,
        meta: def.meta ?? {},
        route,
        errorCodes: Object.keys(def.errorMap ?? {}),
        inputIsEventIterator: isEventIteratorSchema(def.inputSchema),
        contract: typeof def.handler !== 'function',
      });
      return;
    }
    for (const [key, value] of Object.entries(node)) {
      await walk(value, [...segments, key]);
    }
  }
}