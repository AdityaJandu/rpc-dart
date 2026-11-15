import { createHash } from 'node:crypto';
import type {
  ContractIR,
  DiscriminatedUnionDef,
  EnumDef,
  FieldDef,
  ObjectDef,
  SimpleUnionDef,
  TypeDef,
  TypeRef,
} from '@rpc-dart/core';
import {
  fieldName,
  modelFileName,
  procClassName,
  procedureFileName,
  routerClassName,
} from './naming.js';

export interface EmitOptions {
  packageName?: string;
}

export interface EmitResult {
  /** Relative POSIX path -> file content. */
  files: Record<string, string>;
}

const RUNTIME_PACKAGE = 'trpc_dart';

const GENERATOR_VERSION = '0.1.4';
const MODEL_DIR = 'lib/src/api/models';
const PROC_DIR = 'lib/src/api/procedures';
const ROUTER_DIR = 'lib/src/api/routers';
const API_PATH = 'lib/src/api/api.dart';
const MANIFEST_PATH = 'lib/src/api/generated.rpc-dart.json';

interface FileCtx {
  trpcSymbols: Set<string>;
  modelNames: Set<string>;
  body: string[];
}

function newFile(): FileCtx {
  return { trpcSymbols: new Set(), modelNames: new Set(), body: [] };
}

function add(f: FileCtx, line = ''): void {
  f.body.push(line);
}

function isRef(type: TypeRef): type is { $ref: string } {
  return typeof type === 'object' && type !== null && '$ref' in type;
}

interface Emitter {
  ir: ContractIR;
  registry: Record<string, TypeDef>;
}

function defByRef(em: Emitter, type: TypeRef): TypeDef {
  if (!isRef(type)) throw new Error(`expected a $ref, got ${JSON.stringify(type)}`);
  const def = em.registry[type.$ref];
  if (!def) throw new Error(`missing registry entry ${type.$ref}`);
  return def;
}

function namedName(def: TypeDef): string {
  switch (def.kind) {
    case 'object':
    case 'enum':
    case 'simpleUnion':
    case 'discriminatedUnion':
      return def.name;
    default:
      throw new Error(`unnamed kind ${def.kind} cannot be referenced`);
  }
}

function primitiveDart(primitive: string): string {
  switch (primitive) {
    case 'string':
      return 'String';
    case 'number':
      return 'double';
    case 'boolean':
      return 'bool';
    case 'Date':
      return 'DateTime';
    case 'BigInt':
      return 'BigInt';
    case 'JsonValue':
      return 'JsonValue';
    default:
      return 'Object?';
  }
}

function dartTypeOf(em: Emitter, f: FileCtx, type: TypeRef): string {
  if (typeof type === 'string') return primitiveDart(type);
  if (isRef(type)) {
    const def = defByRef(em, type);
    f.modelNames.add(namedName(def));
    return namedName(def);
  }
  switch (type.kind) {
    case 'object':
    case 'enum':
    case 'simpleUnion':
    case 'discriminatedUnion':
      return type.name;
    case 'list':
      return `List<${dartTypeOf(em, f, type.element)}>`;
    case 'set':
      return `Set<${dartTypeOf(em, f, type.element)}>`;
    case 'record':
      return `Map<${dartTypeOf(em, f, type.keyType)}, ${dartTypeOf(em, f, type.valueType)}>`;
    case 'tuple':
      return `(${type.items.map((i) => dartTypeOf(em, f, i)).join(', ')})`;
    case 'nullable':
      return `${dartTypeOf(em, f, type.inner)}?`;
    case 'unknown':
      f.trpcSymbols.add('JsonValue');
      return 'JsonValue';
    case 'literal':
      return 'Object?';
    default:
      return 'Object?';
  }
}

function isCollectionish(em: Emitter, type: TypeRef): boolean {
  if (typeof type === 'string') return false;
  if (isRef(type)) {
    const def = em.registry[type.$ref];
    if (!def) return false;
    return def.kind === 'object' || def.kind === 'discriminatedUnion';
  }
  return type.kind === 'list' || type.kind === 'set' || type.kind === 'record' ||
    (type.kind === 'nullable' && isCollectionish(em, type.inner));
}

// ---------------------------------------------------------------------------
// Decode / encode expressions
// ---------------------------------------------------------------------------

function decoderFor(em: Emitter, f: FileCtx, type: TypeRef): string {
  if (typeof type === 'string') {
    switch (type) {
      case 'string':
        return 'RpcJson.asString';
      case 'number':
        return 'RpcJson.asDouble';
      case 'boolean':
        return 'RpcJson.asBool';
      case 'Date':
        return 'RpcJson.asDateTime';
      case 'BigInt':
        return 'RpcJson.asBigInt';
      case 'JsonValue':
        return 'JsonValue.fromJsonOf';
      default:
        return 'JsonValue.fromJsonOf';
    }
  }
  if (isRef(type)) {
    const def = defByRef(em, type);
    f.modelNames.add(namedName(def));
    return `${namedName(def)}.fromJsonOf`;
  }
  switch (type.kind) {
    case 'object':
    case 'enum':
    case 'simpleUnion':
    case 'discriminatedUnion':
      f.modelNames.add(type.name);
      return `${type.name}.fromJsonOf`;
    case 'list':
      return `(v, path) => RpcJson.asList(v, ${decoderFor(em, f, type.element)}, path)`;
    case 'set':
      return `(v, path) => RpcJson.asSet(v, ${decoderFor(em, f, type.element)}, path)`;
    case 'record':
      return `(v, path) => RpcJson.asTypedMap(v, RpcJson.asString, ${decoderFor(em, f, type.valueType)}, path)`;
    case 'nullable':
      return decoderFor(em, f, type.inner);
    case 'tuple': {
      const parts = type.items
        .map((item, index) => {
          const scalar = decoderFor(em, f, item);
          return scalar.startsWith('RpcJson.')
            ? `RpcJson.${scalar.slice('RpcJson.'.length)}.call(parts[${index}], '$path[${index}]')`
            : `${scalar}.call(parts[${index}], '$path[${index}]')`;
        })
        .join(', ');
      return `(v, path) {
        final parts = RpcJson.tupleItems(v, ${type.items.length}, path);
        return (${parts});
      }`;
    }
    case 'unknown':
      f.trpcSymbols.add('JsonValue');
      return 'JsonValue.fromJsonOf';
    default:
      throw new Error(`no decoder for kind ${type.kind}`);
  }
}

function encodeValue(em: Emitter, f: FileCtx, value: string, type: TypeRef): string {
  if (typeof type === 'string') return value;
  if (isRef(type)) {
    const def = defByRef(em, type);
    const name = namedName(def);
    void name;
    if (def.kind === 'enum' || def.kind === 'simpleUnion' || def.kind === 'object' ||
      def.kind === 'discriminatedUnion') {
      return `${value}.toJson()`;
    }
    return value;
  }
  switch (type.kind) {
    case 'tuple':
      return `[${type.items.map((_, index) => `${value}.$${index + 1}`).join(', ')}]`;
    case 'set':
      if (typeof type.element === 'string') return `${value}.toList()`;
      return `${value}.map((e) => ${encodeValue(em, f, 'e', type.element)}).toList()`;
    case 'list':
      if (typeof type.element === 'string') return value;
      return `${value}.map((e) => ${encodeValue(em, f, 'e', type.element)}).toList()`;
    case 'record': {
      if (dartTypeOf(em, f, type.valueType) === 'JsonValue') {
        f.trpcSymbols.add('JsonValue');
        return `${value}.map((k, v) => MapEntry(k, v.toJson()))`;
      }
      return value;
    }
    case 'unknown':
      f.trpcSymbols.add('JsonValue');
      return `${value}.toJson()`;
    default:
      return value;
  }
}

// ---------------------------------------------------------------------------
// Field plans
// ---------------------------------------------------------------------------

interface FieldPlan {
  declaration: string;
  ctorParam: string;
  fromJson: string;
  toJsonEntry: string | null;      // inside the map literal (required fields)
  toJsonStatements: string[];      // conditional writes after the literal
  equality: string;
  copyWithParam: string;
  copyWithArg: string;
}

function planField(em: Emitter, f: FileCtx, field: FieldDef, parentModel = ''): FieldPlan {
  const name = fieldName(field.name);
  const wire = JSON.stringify(field.wireName);
  const T = dartTypeOf(em, f, field.type);
  const deepEq = isCollectionish(em, field.type);
  if (deepEq) f.trpcSymbols.add('rpcDeepEquals');
  const equality = deepEq ? `rpcDeepEquals(${name}, other.${name})` : `${name} == other.${name}`;
  if (deepEq) f.trpcSymbols.add('rpcDeepHash');

  f.trpcSymbols.add('RpcJson');
  const decoder = decoderFor(em, f, field.type);
  const plan: FieldPlan = {
    declaration: `final ${T} ${name};`,
    ctorParam: `required this.${name},`,
    fromJson: `${name}: RpcJson.requiredField(json, ${wire}, ${decoder}, model: ${JSON.stringify(parentModel)}),`,
    toJsonEntry: `"${field.wireName}": ${encodeValue(em, f, name, field.type)},`,
    toJsonStatements: [],
    equality,
    copyWithParam: `${T}? ${name}`,
    copyWithArg: `${name} ?? this.${name}`,
  };

  if (field.optional && field.nullable) {
    f.trpcSymbols.add('RpcOpt');
    plan.declaration = `final RpcOpt<${T}>? ${name};`;
    plan.ctorParam = `this.${name},`;
    plan.copyWithParam = `RpcOpt<${T}>? ${name}`;
    plan.fromJson = `${name}: RpcOpt.decode(json, ${wire}, decode: ${decoder}, model: ${JSON.stringify(parentModel)}),`;
    plan.toJsonEntry = null;
    plan.toJsonStatements = [
      `final ${name}Value = ${name};`,
      `if (${name}Value is RpcPresent<${T}>) json[${wire}] = ${encodeValue(em, f, `${name}Value.value`, field.type)};`,
      `else if (${name}Value is RpcNull<${T}>) json[${wire}] = null;`,
    ];
    return plan;
  }

  if (field.optional && !field.nullable) {
    plan.declaration = `final ${T}? ${name};`;
    plan.ctorParam = `this.${name},`;
    plan.copyWithParam = `${T}? ${name}`;
    plan.fromJson = `${name}: RpcJson.optionalField(json, ${wire}, ${decoder}, model: ${JSON.stringify(parentModel)}),`;
    plan.toJsonEntry = null;
    plan.toJsonStatements = [
      `if (${name} != null) json[${wire}] = ${encodeValue(em, f, `${name}!`, field.type)};`,
    ];
    return plan;
  }

  if (!field.optional && field.nullable) {
    plan.declaration = `final ${T}? ${name};`;
    plan.copyWithParam = `${T}? ${name}`;
    plan.fromJson = `${name}: RpcJson.optionalField(json, ${wire}, ${decoder}, model: ${JSON.stringify(parentModel)}),`;
    return plan;
  }

  return plan;
}

// ---------------------------------------------------------------------------
// Renderers
// ---------------------------------------------------------------------------

function renderObjectModel(em: Emitter, def: ObjectDef): FileCtx {
  const f = newFile();
  const className = def.name;
  const plans = def.fields.map((field) => planField(em, f, field, className));

  // Imports: models referenced by this file (excluding itself).
  for (const field of def.fields) {
    collectModelImports(em, f, field.type);
  }


  add(f, `class ${className} {`);
  add(f, `  const ${className}({`);
  for (let i = 0; i < def.fields.length; i++) {
    add(f, `    ${plans[i]!.ctorParam}`);
  }
  add(f, '  });');
  add(f);
  add(f, `  factory ${className}.fromJson(Map<String, Object?> json) => ${className}(`);
  for (let i = 0; i < def.fields.length; i++) {
    add(f, `        ${plans[i]!.fromJson}`);
  }
  add(f, '      );');
  add(f);
  add(f, `  static ${className} fromJsonOf(Object? value, String path) =>`);
  add(f, `      ${className}.fromJson(RpcJson.asMap(value, path));`);
  add(f);
  for (let i = 0; i < def.fields.length; i++) {
    add(f, `  ${plans[i]!.declaration}`);
  }
  if (def.fields.length > 0) add(f);
  for (let i = 0; i < def.fields.length; i++) {
    const field = def.fields[i]!;
    if (field.optional && field.nullable) {
      const T = dartTypeOf(em, f, field.type);
      add(f, `  ${T}? get ${fieldName(field.name)}OrNull => ${fieldName(field.name)}?.valueOrNull;`);
      add(f);
    }
  }
  add(f, `  ${className} copyWith({`);
  for (let i = 0; i < def.fields.length; i++) {
    add(f, `    ${plans[i]!.copyWithParam},`);
  }
  add(f, '  }) =>');
  add(f, `      ${className}(`);
  for (let i = 0; i < def.fields.length; i++) {
    const n = fieldName(def.fields[i]!.name);
    add(f, `        ${n}: ${plans[i]!.copyWithArg},`);
  }
  add(f, '      );');
  add(f);
  add(f, '  @override');
  add(f, '  bool operator ==(Object other) =>');
  add(f, '      identical(this, other) ||');
  add(f, `      other is ${className} &&`);
  const eq = plans.map((p) => p.equality);
  if (eq.length === 0) {
    f.body[f.body.length - 2] = `      other is ${className};`;
  } else {
    add(f, `          ${eq.join(' &&\n          ')};`);
  }
  add(f);
  add(f, '  @override');
  const hashArgs = def.fields.map((field) => {
    const n = fieldName(field.name);
    return isCollectionish(em, field.type) ? `rpcDeepHash(${n})` : n;
  });
  add(f, hashArgs.length > 1
    ? `  int get hashCode => Object.hash(${hashArgs.join(', ')});`
    : hashArgs.length === 1
      ? `  int get hashCode => ${hashArgs[0]}.hashCode;`
      : `  int get hashCode => ${className}.hashCode;`);
  add(f);
  add(f, '  @override');
  add(f, `  String toString() => '${className}(${def.fields.map((fl) => `${fieldName(fl.name)}: $${fieldName(fl.name)}`).join(', ')})';`);
  add(f);
  add(f, '  Map<String, Object?> toJson() {');
  add(f, '    final json = <String, Object?>{');
  for (const entry of plans.flatMap((p) => (p.toJsonEntry === null ? [] : [p.toJsonEntry]))) {
    add(f, `      ${entry}`);
  }
  add(f, '    };');
  for (const statement of plans.flatMap((p) => p.toJsonStatements)) {
    add(f, `    ${statement}`);
  }
  add(f, '    return json;');
  add(f, '  }');
  add(f, '}');

  return f;
}

function collectModelImports(em: Emitter, f: FileCtx, type: TypeRef): void {
  if (typeof type === 'string') return;
  if (isRef(type)) {
    f.modelNames.add(namedName(defByRef(em, type)));
    return;
  }
  switch (type.kind) {
    case 'list':
    case 'set':
      collectModelImports(em, f, type.element);
      break;
    case 'record':
      collectModelImports(em, f, type.valueType);
      break;
    case 'nullable':
      collectModelImports(em, f, type.inner);
      break;
    default:
      break;
  }
}

function renderEnum(_em: Emitter, def: EnumDef | SimpleUnionDef): FileCtx {
  const f = newFile();
  const isNumeric = def.values.some((v) => typeof v === 'number');
  const unknownRaw = isNumeric ? 'rpcUnknownEnumNumRaw' : 'rpcUnknownEnumRaw';
  f.trpcSymbols.add(unknownRaw);
  f.trpcSymbols.add('RpcEnumUnknownException');
  add(f, `enum ${def.name} {`);
  for (const value of def.values) {
    const raw = isNumeric ? String(value) : JSON.stringify(value);
    add(f, `  ${sanitizeEnumValue(String(value))}(${raw}),`);
  }
  add(f, `  $unknown(${unknownRaw});`);
  add(f);
  add(f, `  const ${def.name}(this.raw);`);
  add(f);
  add(f, `  final ${isNumeric ? 'num' : 'String'} raw;`);
  add(f);
  add(f, `  static ${def.name} fromJson(${isNumeric ? 'num' : 'String'} raw) =>`);
  add(f, `      ${def.name}.values.firstWhere((v) => v.raw == raw, orElse: () => ${def.name}.$unknown);`);
  add(f);
  add(f, `  static ${def.name} fromJsonOf(Object? value, String path) =>`);
  add(f, `      ${def.name}.fromJson(RpcJson.as${isNumeric ? 'Num' : 'String'}(value, path));`);
  add(f);
  add(f, `  ${isNumeric ? 'num' : 'String'} toJson() => raw == ${unknownRaw}`);
  add(f, `      ? throw RpcEnumUnknownException('${def.name}')`);
  add(f, '      : raw;');
  add(f, '}');
  return f;
}

function sanitizeEnumValue(value: string): string {
  if (/^[a-zA-Z_$][a-zA-Z0-9_$]*$/.test(value)) return value;
  return `value_${value.replace(/[^a-zA-Z0-9]/g, '_')}`;
}

function renderUnion(em: Emitter, def: DiscriminatedUnionDef): FileCtx {
  const f = newFile();
  f.trpcSymbols.add('rpcDeepEquals');
  f.trpcSymbols.add('rpcDeepHash');
  add(f, `sealed class ${def.name} {`);
  add(f, `  const ${def.name}();`);
  add(f);
  add(f, `  factory ${def.name}.fromJson(Map<String, Object?> json) => switch (json[${JSON.stringify(def.tagField)}]) {`);
  for (const variant of def.variants) {
    const variantName = namedName(defByRef(em, variant.object));
    add(f, `        ${JSON.stringify(variant.tag)} => ${variantName}.fromJson(json),`);
  }
  add(f, `        _ => ${def.name}Unknown.fromJson(json),`);
  add(f, '      };');
  add(f);
  add(f, '  Map<String, Object?> toJson();');
  add(f);
  add(f, `  static ${def.name} fromJsonOf(Object? value, String path) =>`);
  add(f, `      ${def.name}.fromJson(RpcJson.asMap(value, path));`);
  add(f, '}');
  add(f);
  for (const variant of def.variants) {
    const variantDef = defByRef(em, variant.object) as ObjectDef;
    renderVariant(em, f, def, variantDef);
  }
  add(f, `final class ${def.name}Unknown extends ${def.name} {`);
  add(f, `  const ${def.name}Unknown(this.raw);`);
  add(f);
  add(f, `  factory ${def.name}Unknown.fromJson(Map<String, Object?> json) => ${def.name}Unknown(json);`);
  add(f);
  add(f, '  final Map<String, Object?> raw;');
  add(f);
  add(f, '  @override');
  add(f, '  bool operator ==(Object other) =>');
  add(f, '      identical(this, other) ||');
  add(f, `      other is ${def.name}Unknown && rpcDeepEquals(raw, other.raw);`);
  add(f);
  add(f, '  @override');
  add(f, `  int get hashCode => Object.hash('${def.name}Unknown', rpcDeepHash(raw));`);
  add(f);
  add(f, '  @override');
  add(f, `  String toString() => '${def.name}Unknown(raw: $raw)';`);
  add(f);
  add(f, '  @override');
  add(f, '  Map<String, Object?> toJson() => raw;');
  add(f, '}');
  return f;
}

function renderVariant(em: Emitter, f: FileCtx, union: DiscriminatedUnionDef, variantDef: ObjectDef): void {
  const className = variantDef.name;
  const fields = variantDef.fields.filter((fl) => fl.name !== union.tagField);
  const plans = fields.map((fl) => planField(em, f, fl, className));
  add(f, `final class ${className} extends ${union.name} {`);
  add(f, `  const ${className}({`);
  for (let i = 0; i < fields.length; i++) {
    add(f, `    ${plans[i]!.ctorParam}`);
  }
  add(f, '  });');
  add(f);
  add(f, `  factory ${className}.fromJson(Map<String, Object?> json) => ${className}(`);
  for (let i = 0; i < fields.length; i++) {
    add(f, `        ${plans[i]!.fromJson}`);
  }
  add(f, '      );');
  add(f);
  for (let i = 0; i < fields.length; i++) {
    add(f, `  ${plans[i]!.declaration}`);
  }
  add(f);
  if (fields.length > 0) {
    add(f, `  ${className} copyWith({`);
    for (let i = 0; i < fields.length; i++) {
      add(f, `    ${plans[i]!.copyWithParam},`);
    }
    add(f, '  }) =>');
    add(f, `      ${className}(`);
    for (let i = 0; i < fields.length; i++) {
      const n = fieldName(fields[i]!.name);
      add(f, `        ${n}: ${n} ?? this.${n},`);
    }
    add(f, '      );');
    add(f);
  }
  add(f, '  @override');
  add(f, '  bool operator ==(Object other) =>');
  add(f, '      identical(this, other) ||');
  add(f, `      other is ${className} &&`);
  add(f, `          ${plans.length > 0 ? plans.map((p) => p.equality).join(' &&\n          ') : 'true'};`);
  add(f);
  add(f, '  @override');
  const hashArgs = fields.map((fl) => {
    const n = fieldName(fl.name);
    return isCollectionish(em, fl.type) ? `rpcDeepHash(${n})` : n;
  });
  add(f, hashArgs.length > 0
    ? `  int get hashCode => Object.hash('${className}', ${hashArgs.join(', ')});`
    : `  int get hashCode => Object.hash('${className}');`);
  add(f);
  add(f, '  @override');
  add(f, `  String toString() => '${className}(${fields.map((fl) => `${fieldName(fl.name)}: $${fieldName(fl.name)}`).join(', ')})';`);
  add(f);
  add(f, '  @override');
  add(f, '  Map<String, Object?> toJson() => {');
  add(f, `        ${JSON.stringify(union.tagField)}: ${JSON.stringify(union.variants.find((v) => namedName(defByRef(em, v.object)) === className)!.tag)},`);
  for (let i = 0; i < fields.length; i++) {
    const fl = fields[i]!;
    add(f, `        ${JSON.stringify(fl.wireName)}: ${encodeValue(em, f, fieldName(fl.name), fl.type)},`);
  }
  add(f, '      };');
  add(f, '}');
  add(f);
}

function renderProcedure(em: Emitter, path: string): FileCtx {
  const f = newFile();
  f.trpcSymbols.add('RpcClient');
  f.trpcSymbols.add('RpcRequest');
  f.trpcSymbols.add('RpcProcedureKind');
  f.trpcSymbols.add('RpcCallContext');
  f.trpcSymbols.add('RpcQueryKey');
  f.trpcSymbols.add('RpcResult');
  f.trpcSymbols.add('RpcSuccess');
  f.trpcSymbols.add('RpcFailure');
  f.trpcSymbols.add('RpcException');
  const record = em.ir.procedures[path]!;
  const kind = record.kind;
  const hasInput = record.input !== null;
  const inputName = hasInput ? namedName(defByRef(em, record.input!)) : null;
  const outputName = namedName(defByRef(em, record.output));
  const segments = path.split('.');
  const isQuery = kind === 'query';

  if (hasInput) f.modelNames.add(inputName!);
  f.modelNames.add(outputName);
  const callMethod = isQuery ? 'query' : 'mutate';
  const safeMethod = isQuery ? 'safeQuery' : 'safeMutate';
  const inputParam = hasInput ? `${inputName} input, ` : '';
  const inputArg = hasInput ? 'input.toJson(),' : 'null,';
  const inputPass = hasInput ? 'input, ' : '';

  const implementsClause = isQuery && hasInput
    ? ` implements RpcWatchable<${inputName}, ${outputName}>`
    : isQuery
      ? ' implements RpcWatchableNoInput<' + outputName + '>'
      : '';
  add(f, `class ${procClassName(path)}${implementsClause} {`);
  add(f, `  const ${procClassName(path)}(this._client);`);
  add(f);
  add(f, '  final RpcClient _client;');
  add(f);
  add(f, `  static const path = '${path}';`);
  add(f);
  add(f, `  RpcQueryKey get pathKey => RpcQueryKey(path: const [${segments.map((s) => JSON.stringify(s)).join(', ')}]);`);
  add(f);
  if (isQuery) {
    if (hasInput) {
      add(f, `  RpcQueryKey queryKey(${inputName} input) =>`);
      add(f, `      RpcQueryKey(path: const [${segments.map((s) => JSON.stringify(s)).join(', ')}], input: input);`);
    } else {
      add(f, `  RpcQueryKey get queryKey => RpcQueryKey(path: const [${segments.map((s) => JSON.stringify(s)).join(', ')}]);`);
    }
    add(f);
  }
  add(f, `  Future<${outputName}> ${callMethod}(${inputParam}{RpcCallContext? context}) async {`);
  add(f, '    final data = await _client.execute(');
  add(f, '      RpcRequest(');
  add(f, '        path: path,');
  add(f, `        kind: RpcProcedureKind.${kind},`);
  add(f, `        input: ${inputArg}`);
  add(f, '        context: context,');
  add(f, '      ),');
  add(f, '    );');
  add(f, `    return ${outputName}.fromJson(RpcJson.asMap(data, path));`);
  add(f, '  }');
  add(f);
  add(f, `  Future<RpcResult<${outputName}>> ${safeMethod}(${inputParam}{RpcCallContext? context}) async {`);
  add(f, '    try {');
  add(f, `      return RpcSuccess<${outputName}>(await ${callMethod}(${inputPass}context: context));`);
  add(f, '    } on RpcException catch (error) {');
  add(f, `      return RpcFailure<${outputName}>(error);`);
  add(f, '    }');
  add(f, '  }');
  if (isQuery) {
    add(f);
    f.trpcSymbols.add('RpcQueryRef');
    add(f, `  RpcQueryRef<${outputName}> watch(${inputParam}{RpcCallContext? context}) {`);
    add(f, `    return _client.cache.watch<${outputName}>(`);
    add(f, hasInput ? '      queryKey(input),' : '      queryKey,');
    add(f, `      () => ${callMethod}(${inputPass}context: context),`);
    add(f, '    );');
    add(f, '  }');
  }
  add(f, '}');
  return f;
}

function renderRouter(_em: Emitter, routerPath: string, leaves: string[]): FileCtx {
  const f = newFile();
  f.trpcSymbols.add('RpcQueryKey');
  const className = routerClassName(lastSegment(routerPath));
  const segments = routerPath.length === 0 ? [] : routerPath.split('.');
  const sortedLeaves = [...leaves].sort();
  add(f, `class ${className} {`);
  add(f, `  ${className}(this._client);`);
  add(f);
  add(f, '  final RpcClient _client;');
  add(f);
  add(f, `  RpcQueryKey get pathKey => RpcQueryKey(path: const [${segments.map((s) => JSON.stringify(s)).join(', ')}]);`);
  add(f);
  for (const leaf of sortedLeaves) {
    const fullPath = routerPath.length === 0 ? leaf : `${routerPath}.${leaf}`;
    add(f, `  ${procClassName(fullPath)} get ${fieldName(leaf)} => ${procClassName(fullPath)}(_client);`);
    add(f);
  }
  add(f, '}');
  return { ...f, imports: sortedLeaves.map((leaf) => {
    const fullPath = routerPath.length === 0 ? leaf : `${routerPath}.${leaf}`;
    return `import '../procedures/${procedureFileName(fullPath)}';`;
  }) } as FileCtx & { imports: string[] };
}

function lastSegment(path: string): string {
  return path.split('.').pop()!;
}

function renderApi(em: Emitter, routerSegments: string[], rootLeaves: string[] = []): FileCtx {
  const f = newFile();
  f.trpcSymbols.add('RpcClient');
  f.trpcSymbols.add('RpcQueryCache');
  f.trpcSymbols.add('RpcQueryKey');
  const variantIds = new Set<string>();
  for (const def of Object.values(em.registry)) {
    if (def.kind === 'discriminatedUnion') {
      for (const variant of def.variants) {
        variantIds.add((variant.object as { $ref: string }).$ref);
      }
    }
  }
  const exportedFiles = new Set<string>();
  for (const [id, def] of Object.entries(em.registry)
    .filter(([, d]) => d.kind === 'object' || d.kind === 'enum' || d.kind === 'simpleUnion' || d.kind === 'discriminatedUnion')) {
    if (variantIds.has(id)) continue;
    const file = modelFileName(namedName(def));
    if (exportedFiles.has(file)) continue;
    exportedFiles.add(file);
    add(f, `export 'models/${file}';`);
  }
  add(f);
  const sorted = [...routerSegments].sort();
  add(f, '/// Generated client bindings. Construct once with an [RpcClient].');
  add(f, 'class Api {');
  if (sorted.length > 0) {
    const initializers = sorted
      .map((s) => `        ${fieldName(s)} = ${routerClassName(s)}(client),`)
      .join('\n')
      .slice(0, -1);
    add(f, `  Api(this.client) :\n${initializers};`);
  } else {
    add(f, '  Api(this.client);');
  }
  add(f);
  add(f, '  final RpcClient client;');
  for (const segment of sorted) {
    add(f, `  final ${routerClassName(segment)} ${fieldName(segment)};`);
  }
  add(f);
  for (const leaf of rootLeaves) {
    const cls = procClassName(leaf);
    add(f, `  ${cls} get ${fieldName(leaf)} => ${cls}(client);`);
    add(f);
  }
  add(f, '  RpcQueryCache get cache => client.cache;');
  add(f);
  add(f, '  void invalidate(RpcQueryKey key) => client.cache.invalidate(key);');
  add(f);
  add(f, '  Stream<RpcQueryKey> onInvalidate([RpcQueryKey? prefix]) =>');
  add(f, '      client.cache.onInvalidate(prefix);');
  add(f, '}');
  return { ...f, imports: sorted.map((s) => `import 'routers/${modelFileName(routerClassName(s))}';`) } as FileCtx & { imports: string[] };
}

interface FileWithImports extends FileCtx {
  imports?: string[];
}

function assembleFile(
  em: Emitter,
  f: FileCtx,
  opts: { imports?: string[]; skipModel?: string; modelImportPrefix?: string } = {},
): string {
  const lines: string[] = [];
  lines.push('// GENERATED CODE - DO NOT MODIFY BY HAND');
  lines.push(`// Generated by rpc-dart ${GENERATOR_VERSION} (contract ${em.ir.hash.slice(0, 23)}).`);
  lines.push('');
  if (f.trpcSymbols.size > 0) {
    lines.push(`import 'package:${RUNTIME_PACKAGE}/${RUNTIME_PACKAGE}.dart';`);
  }
  const modelImports = opts.imports ?? [];
  for (const imp of modelImports) lines.push(imp);
  const prefix = opts.modelImportPrefix ?? '';
  const autoModelImports = opts.imports
    ? []
    : [...f.modelNames]
      .filter((n) => n !== opts.skipModel)
      .sort()
      .map((n) => `import '${prefix}${modelFileName(n)}';`);
  for (const imp of autoModelImports) lines.push(imp);
  lines.push('');
  lines.push(...f.body);
  return lines.join('\n').replace(/\n{3,}/g, '\n\n').trimEnd() + '\n';
}

export function emit(ir: ContractIR, _options: EmitOptions = {}): EmitResult {
  const em: Emitter = { ir, registry: ir.types };
  const files: Record<string, string> = {};

  // Variant classes render inline inside their union file, never standalone.
  const variantIds = new Set<string>();
  for (const id of Object.keys(ir.types).sort()) {
    const def = ir.types[id]!;
    if (def.kind === 'discriminatedUnion') {
      for (const variant of def.variants) {
        variantIds.add((variant.object as { $ref: string }).$ref);
      }
    }
  }

  // 1. Models.
  for (const id of Object.keys(ir.types).sort()) {
    const def = ir.types[id]!;
    if (def.kind === 'object') {
      if (variantIds.has(id)) continue;
      const f = renderObjectModel(em, def);
      files[`${MODEL_DIR}/${modelFileName(def.name)}`] = assembleFile(em, f, {
        skipModel: def.name,
      });
    } else if (def.kind === 'enum' || def.kind === 'simpleUnion') {
      files[`${MODEL_DIR}/${modelFileName(def.name)}`] = assembleFile(em, renderEnum(em, def));
    } else if (def.kind === 'discriminatedUnion') {
      const f = renderUnion(em, def);
      files[`${MODEL_DIR}/${modelFileName(def.name)}`] = assembleFile(em, f);
    }
  }

  // 2. Procedures + router grouping. Root-level procedures (no dot) hang
  // off the Api root instead of a synthetic router.
  const routers = new Map<string, string[]>();
  const rootLeaves: string[] = [];
  for (const path of ir.procedurePaths) {
    const dotIndex = path.lastIndexOf('.');
    const routerPath = dotIndex === -1 ? '' : path.slice(0, dotIndex);
    const leaf = lastSegment(path);
    if (routerPath === '') {
      rootLeaves.push(leaf);
      files[`${PROC_DIR}/${procedureFileName(path)}`] = assembleFile(em, renderProcedure(em, path), { modelImportPrefix: '../models/' });
      continue;
    }
    const list = routers.get(routerPath) ?? [];
    list.push(leaf);
    routers.set(routerPath, list);
    files[`${PROC_DIR}/${procedureFileName(path)}`] = assembleFile(em, renderProcedure(em, path), { modelImportPrefix: '../models/' });
  }

  // 3. Routers.
  for (const routerPath of [...routers.keys()].sort()) {
    const f = renderRouter(em, routerPath, routers.get(routerPath)!) as FileCtx & { imports?: string[] };
    files[`${ROUTER_DIR}/${modelFileName(routerClassName(lastSegment(routerPath)))}`] =
      assembleFile(em, f, { imports: (f as FileWithImports).imports });
  }

  // 4. Api root (router getters + root-level procedure getters).
  {
    const f = renderApi(em, [...routers.keys()], rootLeaves) as FileCtx & { imports?: string[] };
    const imports = [
      ...((f as FileWithImports).imports ?? []),
      ...rootLeaves.map((leaf) => `import 'procedures/${procedureFileName(leaf)}';`),
    ].sort();
    files[API_PATH] = assembleFile(em, f, { imports });
  }

  // 5. Manifest.
  const manifest = {
    irHash: ir.hash,
    generatorVersion: GENERATOR_VERSION,
    protocol: ir.protocol,
    files: Object.keys(files)
      .sort()
      .map((p) => ({ path: p, contentSha256: sha256(files[p]!) })),
  };
  files[MANIFEST_PATH] = `${JSON.stringify(manifest, null, 2)}\n`;

  return { files };
}

function sha256(content: string): string {
  return createHash('sha256').update(content).digest('hex');
}
