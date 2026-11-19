import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { stableStringify, type ContractIR, type FieldDef, type TypeDef } from '@rpc-dart/core';
import { selectAdapter, type AdapterChoice } from '../adapter.js';

export interface DiffEntry {
  kind:
    | 'procedure-removed'
    | 'procedure-renamed'
    | 'procedure-added'
    | 'procedure-kind-changed'
    | 'input-field-added-required'
    | 'input-field-made-required'
    | 'input-type-changed'
    | 'output-field-removed'
    | 'output-type-changed'
    | 'output-nullable-changed'
    | 'enum-value-removed'
    | 'input-field-added-optional'
    | 'input-field-removed'
    | 'output-field-added'
    | 'enum-value-added';
  path: string;
  detail: string;
  breaking: boolean;
}

export interface DiffResult {
  entries: DiffEntry[];
  breakingCount: number;
  nonBreakingCount: number;
  hasBreaking: boolean;
}

export interface DiffOptions {
  tsconfigPath: string;
  entryFile: string;
  exportName: string;
  adapter?: AdapterChoice;
  transformer?: 'superjson' | 'json';
  /** Path to a committed full-IR snapshot (written by --update-baseline). */
  baselinePath: string;
  updateBaseline?: boolean;
}

/** Compares the current contract against a committed IR snapshot. */
export async function diffContract(options: DiffOptions): Promise<DiffResult> {
  const adapter = await selectAdapter(options);
  const { ir: current } = await adapter.extract(options);

  if (options.updateBaseline || !existsSync(options.baselinePath)) {
    if (!options.updateBaseline) {
      throw new Error(
        `baseline snapshot not found at ${options.baselinePath} - run with updateBaseline to write it`,
      );
    }
    writeFileSync(options.baselinePath, `${JSON.stringify(current, null, 2)}\n`);
    return { entries: [], breakingCount: 0, nonBreakingCount: 0, hasBreaking: false };
  }

  const baseline = JSON.parse(readFileSync(options.baselinePath, 'utf-8')) as ContractIR;
  const entries = diffIr(baseline, current);

  if (options.updateBaseline) {
    writeFileSync(options.baselinePath, `${JSON.stringify(current, null, 2)}\n`);
  }

  const breakingCount = entries.filter((e) => e.breaking).length;
  return {
    entries,
    breakingCount,
    nonBreakingCount: entries.length - breakingCount,
    hasBreaking: breakingCount > 0,
  };
}

function typeSignature(type: TypeDef, ir: ContractIR, seen = new Set<string>()): string {
  return stableStringify(stripNamesDeep(type, ir, seen));
}

function stripNamesDeep(type: TypeDef, ir: ContractIR, seen: Set<string>): unknown {
  switch (type.kind) {
    case 'object':
      return {
        kind: 'object',
        fields: type.fields.map((f) => ({
          name: f.name,
          type: stripRefDeep(f.type, ir, seen),
          optional: f.optional,
          nullable: f.nullable,
        })),
      };
    case 'enum':
    case 'simpleUnion':
      return { kind: type.kind, values: type.values };
    case 'discriminatedUnion':
      return {
        kind: type.kind,
        tagField: type.tagField,
        variants: type.variants.map((v) => ({ tag: v.tag, object: stripRefDeep(v.object, ir, seen) })),
      };
    case 'list':
    case 'set':
      return { kind: type.kind, element: stripRefDeep(type.element, ir, seen) };
    case 'record':
      return {
        kind: type.kind,
        keyType: stripRefDeep(type.keyType, ir, seen),
        valueType: stripRefDeep(type.valueType, ir, seen),
      };
    case 'tuple':
      return { kind: type.kind, items: type.items.map((t) => stripRefDeep(t, ir, seen)) };
    case 'nullable':
      return { kind: type.kind, inner: stripRefDeep(type.inner, ir, seen) };
    case 'selfRef':
      return { kind: 'selfRef' };
    default:
      return type;
  }
}

function stripRefDeep(
  type: import('@rpc-dart/core').TypeRef,
  ir: ContractIR,
  seen: Set<string>,
): unknown {
  if (typeof type === 'string') return type;
  if ('$ref' in type) {
    // Resolve the reference so changes INSIDE named types are visible.
    if (seen.has(type.$ref)) return { $ref: 'recursive' };
    seen.add(type.$ref);
    const def = ir.types[type.$ref];
    if (!def) return { $ref: 'unknown' };
    return stripNamesDeep(def, ir, seen);
  }
  return stripNamesDeep(type as TypeDef, ir, seen);
}

function fieldsSignature(fields: FieldDef[]): string {
  return stableStringify(
    fields.map((f) => ({ name: f.name, optional: f.optional, nullable: f.nullable })),
  );
}

/** Structural diff between two contract IRs. */
export function diffIr(baseline: ContractIR, current: ContractIR): DiffEntry[] {
  const entries: DiffEntry[] = [];
  const baselinePaths = Object.keys(baseline.procedures).sort();
  const currentPaths = Object.keys(current.procedures).sort();

  // Rename detection: removed procedures whose shape reappears under a new path.
  const removed = baselinePaths.filter((p) => !currentPaths.includes(p));
  const added = currentPaths.filter((p) => !baselinePaths.includes(p));
  const consumedAdded = new Set<string>();

  for (const path of removed) {
    const oldRecord = baseline.procedures[path]!;
    const renamedTo = added.find((candidate) => {
      if (consumedAdded.has(candidate)) return false;
      const newRecord = current.procedures[candidate]!;
      return (
        newRecord.kind === oldRecord.kind &&
        typeSignature(resolveOutput(oldRecord.output, baseline), baseline) ===
          typeSignature(resolveOutput(newRecord.output, current), current) &&
        fieldsSignature(oldRecord.input === null ? [] : resolveInputFields(oldRecord.input, baseline)) ===
          fieldsSignature(newRecord.input === null ? [] : resolveInputFields(newRecord.input, current))
      );
    });
    if (renamedTo) {
      consumedAdded.add(renamedTo);
      entries.push({
        kind: 'procedure-renamed',
        path,
        detail: `renamed to ${renamedTo}`,
        breaking: true,
      });
    } else {
      entries.push({ kind: 'procedure-removed', path, detail: 'removed', breaking: true });
    }
  }

  for (const path of added) {
    if (consumedAdded.has(path)) continue;
    entries.push({ kind: 'procedure-added', path, detail: 'added', breaking: false });
  }

  for (const path of baselinePaths.filter((p) => currentPaths.includes(p))) {
    const before = baseline.procedures[path]!;
    const after = current.procedures[path]!;
    if (before.kind !== after.kind) {
      entries.push({ kind: 'procedure-kind-changed', path, detail: `${before.kind} -> ${after.kind}`, breaking: true });
      continue;
    }

    const beforeInput = before.input === null ? null : resolveInputFields(before.input, baseline);
    const afterInput = after.input === null ? null : resolveInputFields(after.input, current);
    if ((beforeInput === null) !== (afterInput === null)) {
      entries.push({
        kind: 'input-type-changed',
        path,
        detail: 'input presence changed',
        breaking: true,
      });
    } else if (beforeInput && afterInput) {
      diffInputFields(path, beforeInput, afterInput, entries, baseline, current);
    }

    const beforeOutput = resolveOutput(before.output, baseline);
    const afterOutput = resolveOutput(after.output, current);
    if (typeSignature(beforeOutput, baseline) !== typeSignature(afterOutput, current)) {
      diffOutputFields(path, beforeOutput, afterOutput, entries, baseline, current);
    }
  }

  return entries;
}

type TypeRefLike = import('@rpc-dart/core').TypeRef;

function resolveInputFields(input: TypeRefLike, ir: ContractIR): FieldDef[] {
  const def = resolveDef(input, ir);
  if (def.kind !== 'object') return [];
  return def.fields;
}

function resolveOutput(output: TypeRefLike, ir: ContractIR): TypeDef {
  return resolveDef(output, ir);
}

function resolveDef(type: TypeRefLike, ir: ContractIR): TypeDef {
  if (typeof type === 'string') {
    return { kind: 'primitive', name: type as never };
  }
  if ('$ref' in type) {
    const def = ir.types[type.$ref];
    if (!def) throw new Error(`missing registry entry ${type.$ref}`);
    return def;
  }
  return type as TypeDef;
}

function diffInputFields(
  path: string,
  before: FieldDef[],
  after: FieldDef[],
  entries: DiffEntry[],
  baseline: ContractIR,
  current: ContractIR,
): void {
  const beforeByName = new Map(before.map((f) => [f.name, f]));
  const afterByName = new Map(after.map((f) => [f.name, f]));
  for (const [name, beforeField] of beforeByName) {
    const afterField = afterByName.get(name);
    if (!afterField) {
      entries.push({ kind: 'input-field-removed', path: `${path}#${name}`, detail: 'input field removed', breaking: false });
      continue;
    }
    if (!beforeField.optional && afterField.optional) {
      entries.push({ kind: 'input-field-made-required', path: `${path}#${name}`, detail: 'optional -> required', breaking: true });
    }
    if (typeSignature(beforeField.type as TypeDef, baseline) !== typeSignature(afterField.type as TypeDef, current)) {
      entries.push({ kind: 'input-type-changed', path: `${path}#${name}`, detail: 'input field type changed', breaking: true });
    }
  }
  for (const [name, afterField] of afterByName) {
    if (!beforeByName.has(name)) {
      entries.push({
        kind: afterField.optional ? 'input-field-added-optional' : 'input-field-added-required',
        path: `${path}#${name}`,
        detail: afterField.optional ? 'optional input field added' : 'required input field added',
        breaking: !afterField.optional,
      });
    }
  }
}

function diffOutputFields(
  path: string,
  before: TypeDef,
  after: TypeDef,
  entries: DiffEntry[],
  baseline: ContractIR,
  current: ContractIR,
): void {
  if (before.kind !== 'object' || after.kind !== 'object') {
    entries.push({ kind: 'output-type-changed', path, detail: `output type changed (${before.kind} -> ${after.kind})`, breaking: true });
    return;
  }
  const beforeByName = new Map(before.fields.map((f) => [f.name, f]));
  const afterByName = new Map(after.fields.map((f) => [f.name, f]));
  for (const [name, beforeField] of beforeByName) {
    const afterField = afterByName.get(name);
    if (!afterField) {
      entries.push({ kind: 'output-field-removed', path: `${path}#${name}`, detail: 'output field removed', breaking: true });
      continue;
    }
    if (beforeField.nullable !== afterField.nullable) {
      entries.push({ kind: 'output-nullable-changed', path: `${path}#${name}`, detail: 'output nullability changed', breaking: true });
    }
    if (typeSignature(beforeField.type as TypeDef, baseline) !== typeSignature(afterField.type as TypeDef, current)) {
      entries.push({ kind: 'output-type-changed', path: `${path}#${name}`, detail: 'output field type changed', breaking: true });
    }
  }
  for (const name of afterByName.keys()) {
    if (!beforeByName.has(name)) {
      entries.push({ kind: 'output-field-added', path: `${path}#${name}`, detail: 'output field added', breaking: false });
    }
  }
}
