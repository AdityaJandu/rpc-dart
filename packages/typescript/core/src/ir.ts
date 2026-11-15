/**
 * Contract IR v1 types.
 * Pure declarations - no behavior.
 */

export type JsonValue =
  | null
  | boolean
  | number
  | string
  | JsonValue[]
  | { [key: string]: JsonValue };

export type PrimitiveName =
  | 'string'
  | 'number'
  | 'boolean'
  | 'Date'
  | 'BigInt'
  | 'void'
  | 'never'
  | 'JsonValue';

export interface PrimitiveDef {
  kind: 'primitive';
  name: PrimitiveName;
  numberFormat?: 'int' | 'double';
}

export interface LiteralDef {
  kind: 'literal';
  value: string | number | boolean;
}

export interface EnumDef {
  kind: 'enum';
  name: string;
  /** Raw literal values; numbers for numeric literal unions. */
  values: Array<string | number>;
}

export interface SimpleUnionDef {
  kind: 'simpleUnion';
  name: string;
  values: string[];
}

export interface FieldDef {
  name: string;
  wireName: string;
  type: TypeRef;
  optional: boolean;
  nullable: boolean;
  docs?: string;
}

export interface ObjectDef {
  kind: 'object';
  name: string;
  fields: FieldDef[];
}

export interface DiscriminatedUnionVariant {
  tag: string | number;
  object: TypeRef;
}

export interface DiscriminatedUnionDef {
  kind: 'discriminatedUnion';
  name: string;
  tagField: string;
  variants: DiscriminatedUnionVariant[];
}

export interface ListDef {
  kind: 'list';
  element: TypeRef;
}

export interface SetDef {
  kind: 'set';
  element: TypeRef;
}

export interface RecordDef {
  kind: 'record';
  keyType: TypeRef;
  valueType: TypeRef;
}

export interface TupleDef {
  kind: 'tuple';
  items: TypeRef[];
}

export interface NullableDef {
  kind: 'nullable';
  inner: TypeRef;
}

export interface UnknownDef {
  kind: 'unknown';
}

/**
 * Transient marker produced during recursive-type classification; the
 * assembler resolves it into a $ref to the enclosing named type. It never
 * appears in a serialized IR.
 */
export interface SelfRefDef {
  kind: 'selfRef';
  name: string;
}

export type TypeDef =
  | PrimitiveDef
  | LiteralDef
  | EnumDef
  | SimpleUnionDef
  | ObjectDef
  | DiscriminatedUnionDef
  | ListDef
  | SetDef
  | RecordDef
  | TupleDef
  | NullableDef
  | UnknownDef
  | SelfRefDef;

/** Primitive shorthand ("string") | registry reference ({ $ref }) | inline composite def. */
export type TypeRef = string | { $ref: string } | Exclude<TypeDef, PrimitiveDef>;

export type RouterNode =
  | { kind: 'router'; name: string; children: Record<string, RouterNode> }
  | { kind: 'procedure'; path: string };

export interface ProcedureMeta {
  access: 'public' | 'authenticated';
  extra: Record<string, JsonValue>;
}

export interface ProcedureRecord {
  path: string;
  kind: 'query' | 'mutation' | 'subscription';
  input: TypeRef | null;
  output: TypeRef;
  error: TypeRef | null;
  meta: ProcedureMeta;
  deprecated: { message: string; since?: string } | null;
  docs: string | null;
}

export interface ContractIR {
  irVersion: 1;
  generator: { name: string; version: string };
  protocol: { kind: 'trpc' | 'orpc'; version: string; transformer: 'superjson' | 'json' };
  source: {
    entryFile: string;
    exportName: string;
    tsconfigFile: string;
    adapterVersion: string;
  };
  procedurePaths: string[];
  tree: RouterNode;
  procedures: Record<string, ProcedureRecord>;
  types: Record<string, TypeDef>;
  hash: string;
}

export function isPrimitiveRef(type: TypeRef): type is PrimitiveName {
  return typeof type === 'string';
}

export function isRef(type: TypeRef): type is { $ref: string } {
  return typeof type === 'object' && type !== null && '$ref' in type;
}
