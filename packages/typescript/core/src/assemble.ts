import { computeIrHash, stableStringify } from './canonical.js';
import {
  isPrimitiveRef,
  isRef,
  type ContractIR,
  type DiscriminatedUnionDef,
  type EnumDef,
  type ObjectDef,
  type ProcedureMeta,
  type ProcedureRecord,
  type RouterNode,
  type SimpleUnionDef,
  type TypeDef,
  type TypeRef,
} from './ir.js';

export interface AssembleEntry {
  path: string;
  kind: ProcedureRecord['kind'];
  input: TypeDef | null;
  output: TypeDef;
  meta: ProcedureMeta;
  docs?: string | null;
}

export interface AssembleOptions {
  generator: { name: string; version: string };
  protocol: { kind: 'trpc' | 'orpc'; version: string; transformer: 'superjson' | 'json' };
  source: {
    entryFile: string;
    exportName: string;
    tsconfigFile: string;
    adapterVersion: string;
  };
  entries: AssembleEntry[];
}

const NAMED_KINDS = new Set(['object', 'enum', 'simpleUnion', 'discriminatedUnion']);

function namedName(def: TypeDef): string {
  switch (def.kind) {
    case 'object':
    case 'enum':
    case 'simpleUnion':
    case 'discriminatedUnion':
      return def.name;
    default:
      throw new Error(`unnamed kind ${def.kind} has no name`);
  }
}

function isNamed(def: TypeDef): boolean {
  return NAMED_KINDS.has(def.kind);
}

/** Structural signature: names stripped, everything else canonicalized. */
function stripNames(def: TypeDef): unknown {
  switch (def.kind) {
    case 'object':
      return {
        kind: def.kind,
        fields: def.fields.map((f) => ({
          name: f.name,
          wireName: f.wireName,
          type: stripRef(f.type),
          optional: f.optional,
          nullable: f.nullable,
        })),
      };
    case 'discriminatedUnion':
      return {
        kind: def.kind,
        tagField: def.tagField,
        variants: def.variants.map((v) => ({ tag: v.tag, object: stripRef(v.object) })),
      };
    case 'selfRef':
      return { kind: 'selfRef' }; // identity normalizes away for dedup
    default:
      return def;
  }
}

function stripRef(type: TypeRef): unknown {
  if (typeof type === 'string') return type;
  if (isRef(type)) return { $ref: 'normalized' }; // all refs are structurally equal
  return stripNames(type as TypeDef);
}

/**
 * Interns a shape into the type registry: nested named shapes get interned
 * first, the shape itself is deduplicated by structural signature
 * (first-seen name wins; traversal is sorted-path so names are stable).
 */
function createIntertype() {
  const registry = new Map<string, TypeDef>();
  const assigned: Array<{ id: string; def: TypeDef | null }> = [];
  const nameToId = new Map<string, string>();
  let nextId = 1;

  function internRef(type: TypeRef): TypeRef {
    if (typeof type === 'string') return type;
    if (isRef(type)) return type;
    return intern(type);
  }

  function internChildren(def: TypeDef): TypeDef {
    switch (def.kind) {
      case 'object':
        return {
          ...def,
          fields: def.fields.map((f) => ({ ...f, type: internRef(f.type) })),
        };
      case 'list':
      case 'set':
        return { ...def, element: internRef(def.element) };
      case 'record':
        return { ...def, keyType: internRef(def.keyType), valueType: internRef(def.valueType) };
      case 'tuple':
        return { ...def, items: def.items.map(internRef) };
      case 'nullable':
        return { ...def, inner: internRef(def.inner) };
      case 'discriminatedUnion':
        return {
          ...def,
          variants: def.variants.map((v) => ({ ...v, object: internRef(v.object) })),
        };
      default:
        return def;
    }
  }

  function intern(def: TypeDef): TypeRef {
    if (def.kind === 'primitive') return def.name;
    if (def.kind === 'selfRef') {
      const id = nameToId.get(def.name);
      if (!id) throw new Error(`self-reference to unknown type "${def.name}"`);
      return { $ref: id };
    }
    // Named defs reserve their id/name BEFORE interning children so
    // recursive self-references resolve to this entry. Unnamed defs stay
    // inline.
    if (!isNamed(def)) {
      return internChildren(def) as Exclude<TypeDef, { kind: 'primitive' | 'selfRef' }>;
    }
    const id = `type-${nextId++}`;
    nameToId.set(namedName(def), id);
    const resolved = internChildren(def) as Exclude<TypeDef, { kind: 'primitive' | 'selfRef' }>;
    const signature = stableStringify(stripNames(resolved));
    const existing = registry.get(signature);
    if (existing) return { $ref: findId(existing) };
    registry.set(signature, resolved);
    idByDef.set(resolved, id);
    assigned.push({ id, def: resolved });
    return { $ref: id };
  }

  const idByDef = new Map<TypeDef, string>();
  function findId(def: TypeDef): string {
    const id = idByDef.get(def);
    if (!id) throw new Error('registry inconsistency: interned def lost its id');
    return id;
  }

  return {
    intern,
    types(): Record<string, TypeDef> {
      const out: Record<string, TypeDef> = {};
      for (const entry of assigned) {
        if (entry.def !== null) {
          out[entry.id] = entry.def;
        }
      }
      return out;
    },
  };
}

function buildTree(exportName: string, paths: string[]): RouterNode {
  const root: Extract<RouterNode, { kind: 'router' }> = {
    kind: 'router',
    name: exportName,
    children: {},
  };
  for (const p of paths) {
    const segments = p.split('.');
    let node = root;
    for (let i = 0; i < segments.length - 1; i++) {
      const seg = segments[i]!;
      const existing = node.children[seg];
      if (existing && existing.kind === 'router') {
        node = existing;
      } else {
        const child: Extract<RouterNode, { kind: 'router' }> = {
          kind: 'router',
          name: `${seg}Router`,
          children: {},
        };
        node.children[seg] = child;
        node = child;
      }
    }
    node.children[segments[segments.length - 1]!] = { kind: 'procedure', path: p };
  }
  return sortTree(root);
}

function sortTree(node: RouterNode): RouterNode {
  if (node.kind !== 'router') return node;
  const children: Record<string, RouterNode> = {};
  for (const key of Object.keys(node.children).sort()) {
    children[key] = sortTree(node.children[key]!);
  }
  return { ...node, children };
}

export function assembleContract(options: AssembleOptions): ContractIR {
  const entries = [...options.entries].sort((a, b) => (a.path < b.path ? -1 : 1));
  const intertype = createIntertype();

  const procedures: Record<string, ProcedureRecord> = {};
  for (const entry of entries) {
    procedures[entry.path] = {
      path: entry.path,
      kind: entry.kind,
      input: entry.input === null ? null : intertype.intern(entry.input),
      output: intertype.intern(entry.output),
      error: null,
      meta: entry.meta,
      deprecated: null,
      docs: entry.docs ?? null,
    };
  }

  const procedurePaths = entries.map((e) => e.path);
  const tree = buildTree(options.source.exportName, procedurePaths);
  const types = intertype.types();

  const ir: ContractIR = {
    irVersion: 1,
    generator: options.generator,
    protocol: options.protocol,
    source: options.source,
    procedurePaths,
    tree,
    procedures,
    types,
    hash: '',
  };
  ir.hash = computeIrHash(ir as unknown as Record<string, unknown>);
  return ir;
}

// Re-exported for adapter consumption.
export { isPrimitiveRef, isRef };
export type { EnumDef, ObjectDef, SimpleUnionDef, DiscriminatedUnionDef };
