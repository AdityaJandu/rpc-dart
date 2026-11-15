import type * as tsTypes from 'typescript';
import type {
  DiscriminatedUnionDef,
  EnumDef,
  FieldDef,
  ObjectDef,
  TypeRef,
} from '@rpc-dart/core';
import type { RpcDartDiagnostic } from '@rpc-dart/core';

export class TypeClassificationError extends Error {
  readonly diagnostic: RpcDartDiagnostic;

  constructor(diagnostic: RpcDartDiagnostic) {
    super(`${diagnostic.code}: ${diagnostic.message}`);
    this.name = 'TypeClassificationError';
    this.diagnostic = diagnostic;
  }
}

export function pascal(input: string): string {
  return input
    .split(/[.\-_]/)
    .filter((s) => s.length > 0)
    .map((s) => s.charAt(0).toUpperCase() + s.slice(1))
    .join('');
}

interface DiagnosticContext {
  procedurePath?: string;
  file?: string;
  line?: number;
  column?: number;
}

function fail(code: 'RPCDART0201' | 'RPCDART0202' | 'RPCDART0203', message: string, hint: string, context: DiagnosticContext = {}): TypeClassificationError {
  return new TypeClassificationError({
    code,
    severity: 'error',
    message,
    procedurePath: context.procedurePath,
    file: context.file,
    line: context.line,
    column: context.column,
    hint,
  });
}

/**
 * TypeChecker type -> Contract IR TypeDef. Field optionality/nullability is
 * decided here (undefined -> optional, null -> nullable) so the emitter never
 * sees unions for optionality.
 *
 * Recursive types are handled with an in-progress stack: re-entering a type
 * currently being classified yields a transient selfRef that the assembler
 * resolves into a forward $ref.
 */
export type UnserializablePolicy = 'error' | 'warn-dynamic' | 'skip-procedure';

export class TypeClassifier {
  private readonly cache = new Map<tsTypes.Type, TypeRef>();
  private readonly inProgress = new Set<tsTypes.Type>();
  private readonly stack: string[] = [];
  currentProcedure: string | undefined;

  /** Warnings recorded when per-field warn-dynamic downgrades occur. */
  readonly collectedDiagnostics: RpcDartDiagnostic[] = [];

  constructor(
    private readonly ts: typeof tsTypes,
    private readonly checker: tsTypes.TypeChecker,
    private readonly unserializablePolicy: UnserializablePolicy = 'error',
  ) {}

  classifyProperty(symbol: tsTypes.Symbol, parentName: string): FieldDef {
    const name = symbol.getName();
    const declared = this.checker.getTypeOfSymbol(symbol);
    const optional = this.isOptional(symbol, declared);
    const { stripped, nullable } = this.stripNullish(declared);
    let type: TypeRef;
    try {
      type = this.classify(stripped, `${parentName}${pascal(name)}`);
    } catch (error) {
      if (error instanceof TypeClassificationError) {
        if (error.diagnostic.file === undefined) {
          const location = this.locationOf(symbol);
          if (location) {
            error.diagnostic.file = location.file;
            error.diagnostic.line = location.line;
            error.diagnostic.column = location.column;
          }
        }
        // Per-field warn-dynamic: downgrade only this offending field to an
        // unknown (JsonValue) type and record the warning; siblings stay
        // strongly typed.
        if (this.unserializablePolicy === 'warn-dynamic' && error.diagnostic.code === 'RPCDART0201') {
          error.diagnostic.severity = 'warning';
          this.collectedDiagnostics.push(error.diagnostic);
          return { name, wireName: name, type: { kind: 'unknown' }, optional, nullable };
        }
      }
      throw error;
    }
    return { name, wireName: name, type, optional, nullable };
  }

  classify(type: tsTypes.Type, nameHint: string): TypeRef {
    const cached = this.cache.get(type);
    if (cached) return cached;
    if (this.inProgress.has(type)) {
      // Recursion: the enclosing named type will resolve this marker.
      return { kind: 'selfRef', name: this.stack[this.stack.length - 1] ?? nameHint };
    }
    this.inProgress.add(type);
    try {
      const def = this.classifyUncached(type, nameHint);
      this.cache.set(type, def);
      return def;
    } finally {
      this.inProgress.delete(type);
    }
  }

  private classifyUncached(type: tsTypes.Type, nameHint: string): TypeRef {
    const ts = this.ts;
    const flags = type.flags;

    if (flags & ts.TypeFlags.String) return 'string';
    if (flags & ts.TypeFlags.Number) return 'number';
    if (flags & ts.TypeFlags.Boolean) return 'boolean';
    if (flags & ts.TypeFlags.BigInt) return 'BigInt';
    if (flags & ts.TypeFlags.Void) return 'void';
    if (flags & (ts.TypeFlags.Any | ts.TypeFlags.Unknown)) return { kind: 'unknown' };
    if (flags & ts.TypeFlags.Null || flags & ts.TypeFlags.Undefined) return { kind: 'unknown' };

    if (flags & (ts.TypeFlags.StringLiteral | ts.TypeFlags.NumberLiteral)) {
      return { kind: 'literal', value: (type as tsTypes.StringLiteralType).value };
    }
    if (flags & ts.TypeFlags.BooleanLiteral) {
      const intrinsic = (type as tsTypes.Type & { intrinsicName?: string }).intrinsicName;
      return { kind: 'literal', value: intrinsic === 'true' };
    }

    if (type.isUnion()) return this.classifyUnion(type, nameHint);

    if (flags & ts.TypeFlags.Intersection) {
      // Branded/nominal types (string & BRAND<'X'>) are intersections whose
      // phantom members carry only `__@`-prefixed symbol properties; the
      // real payload is the first non-phantom member.
      const members = (type as tsTypes.IntersectionType).types;
      const nonPhantom = members.filter((member) => {
        const apparent = this.checker.getApparentType(member);
        if (!(apparent.flags & this.ts.TypeFlags.Object)) return true;
        const props = this.checker.getPropertiesOfType(apparent);
        return props.length > 0 && props.some((p2) => !p2.getName().startsWith('__@'));
      });
      if (nonPhantom.length >= 1) {
        return this.classify(nonPhantom[0]!, nameHint);
      }
      throw fail('RPCDART0201', `cannot classify intersection at ${nameHint}`, 'simplify the intersection type', {
        procedurePath: this.currentProcedure,
      });
    }

    if (flags & ts.TypeFlags.Object) {

      const symbol = type.getSymbol() ?? type.aliasSymbol;
      const symbolName = symbol ? symbol.getName() : '';

      if (symbolName === 'Date') return 'Date';
      if (symbolName === 'Function') {
        throw fail(
          'RPCDART0201',
          `unserializable type Function at ${nameHint}`,
          'remove the field from the schema, or set unserializablePolicy in the generator config',
          { procedurePath: this.currentProcedure },
        );
      }
      if (symbolName === 'Promise') {
        throw fail(
          'RPCDART0201',
          `unserializable type Promise at ${nameHint} (async values cannot cross the wire)`,
          'await the promise inside the resolver and return its resolved type',
          { procedurePath: this.currentProcedure },
        );
      }
      if (symbolName === 'Symbol') {
        throw fail('RPCDART0201', `unserializable type Symbol at ${nameHint}`, 'use a string identifier instead', {
          procedurePath: this.currentProcedure,
        });
      }
      if (symbolName === 'RegExp') {
        throw fail('RPCDART0201', `unserializable type RegExp at ${nameHint}`, 'serialize as a string pattern instead', {
          procedurePath: this.currentProcedure,
        });
      }
      if (symbolName === 'Set') {
        const element =
          this.checker.getIndexTypeOfType(type, this.ts.IndexKind.Number) ??
          this.typeArgument(type, 0);
        if (!element) {
          throw fail('RPCDART0201', `Set without a type argument at ${nameHint}`, 'give Set an explicit element type', {
            procedurePath: this.currentProcedure,
          });
        }
        return { kind: 'set', element: this.classify(element, `${nameHint}Item`) };
      }
      if (symbolName === 'Map') {
        const key = this.typeArgument(type, 0);
        const value = this.typeArgument(type, 1);
        if (!key || !value) {
          throw fail('RPCDART0201', `Map without type arguments at ${nameHint}`, 'give Map explicit key and value types', {
            procedurePath: this.currentProcedure,
          });
        }
        const keyType = this.classify(key, `${nameHint}Key`);
        if (typeof keyType !== 'string') {
          throw fail('RPCDART0203', `unmappable map key type at ${nameHint}`, 'use string or enum keys', {
            procedurePath: this.currentProcedure,
          });
        }
        return {
          kind: 'record',
          keyType,
          valueType: this.classify(value, `${nameHint}Value`),
        };
      }
      if (this.checker.isArrayType(type) || symbolName === 'ReadonlyArray') {
        const element =
          this.checker.getIndexTypeOfType(type, this.ts.IndexKind.Number) ??
          this.typeArgument(type, 0);
        if (!element) {
          throw fail('RPCDART0201', `array without element at ${nameHint}`, 'give the array an explicit element type', {
            procedurePath: this.currentProcedure,
          });
        }
        return { kind: 'list', element: this.classify(element, `${nameHint}Item`) };
      }
      if (this.checker.isTupleType(type)) {
        const args = (type as tsTypes.TypeReference).typeArguments ?? [];
        return { kind: 'tuple', items: args.map((a, i) => this.classify(a, `${nameHint}${i}`)) };
      }

      const props = this.checker.getPropertiesOfType(type);
      const indexInfos = this.checker.getIndexInfosOfType(type);
      if (props.length === 0 && this.checker.getSignaturesOfType(type, this.ts.SignatureKind.Call).length > 0) {
        // Anonymous function types (e.g. z.function() inference) carry no
        // Function symbol but are equally unserializable.
        throw fail('RPCDART0201', `unserializable function type at ${nameHint}`, 'remove the field from the schema, or set unserializablePolicy in the generator config', {
          procedurePath: this.currentProcedure,
        });
      }
      if (props.length === 0 && indexInfos.length > 0) {
        const info = indexInfos[0]!;
        if (!info.keyType) {
          throw fail('RPCDART0203', `record key type missing at ${nameHint}`, 'use string keys', {
            procedurePath: this.currentProcedure,
          });
        }
        const keyType = this.classify(info.keyType, `${nameHint}Key`);
        if (typeof keyType !== 'string') {
          throw fail('RPCDART0203', `unmappable record key type at ${nameHint}`, 'use string or enum keys', {
            procedurePath: this.currentProcedure,
          });
        }
        const kind = keyType === 'string' ? this.ts.IndexKind.String : this.ts.IndexKind.Number;
        const valueType = this.checker.getIndexTypeOfType(type, kind);
        if (!valueType) {
          throw fail('RPCDART0203', `record value type missing at ${nameHint}`, 'give the record a value type', {
            procedurePath: this.currentProcedure,
          });
        }
        return {
          kind: 'record',
          keyType,
          valueType: this.classify(valueType, `${nameHint}Value`),
        };
      }
      if (props.length > 0) {
        this.stack.push(nameHint);
        try {
          return this.classifyObject(type, nameHint);
        } finally {
          this.stack.pop();
        }
      }
    }

    throw fail('RPCDART0201', `cannot classify type at ${nameHint}`, 'simplify the type or use a schema primitive', {
      procedurePath: this.currentProcedure,
    });
  }

  private classifyUnion(type: tsTypes.UnionType, nameHint: string): TypeRef {
    const members = type.types.filter(
      (t) => !(t.flags & (this.ts.TypeFlags.Null | this.ts.TypeFlags.Undefined)),
    );
    if (members.length === 0) return { kind: 'unknown' };
    const allLiterals = members.every(
      (t) =>
        (t.flags & (this.ts.TypeFlags.StringLiteral | this.ts.TypeFlags.NumberLiteral)) !== 0,
    );
    if (allLiterals) {
      const values = [
        ...new Set(members.map((t) => (t as tsTypes.StringLiteralType).value as string | number)),
      ].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
      const def: EnumDef = { kind: 'enum', name: nameHint, values };
      return def;
    }
    const du = this.tryDiscriminatedUnion(members, nameHint);
    if (du) return du;
    if (members.length === 1) return this.classify(members[0]!, nameHint);
    throw fail(
      'RPCDART0202',
      `non-discriminated object union at ${nameHint}`,
      'add a literal discriminator field (z.discriminatedUnion) or widen to a single shape',
      { procedurePath: this.currentProcedure },
    );
  }

  private tryDiscriminatedUnion(
    members: tsTypes.Type[],
    nameHint: string,
  ): DiscriminatedUnionDef | null {
    const propsPerMember: Map<string, tsTypes.Symbol>[] = [];
    for (const member of members) {
      if (!(member.flags & this.ts.TypeFlags.Object)) return null;
      const resolved = this.checker.getApparentType(member);
      const props = this.checker.getPropertiesOfType(resolved);
      if (props.length === 0) return null;
      const map = new Map(props.map((s) => [s.getName(), s]));
      propsPerMember.push(map);
    }
    const first = propsPerMember[0]!;
    for (const [tagField] of first) {
      const tags: Array<string | number> = [];
      let viable = true;
      for (const map of propsPerMember) {
        const sym = map.get(tagField);
        if (!sym) {
          viable = false;
          break;
        }
        const t = this.checker.getTypeOfSymbol(sym);
        if (!(t.flags & (this.ts.TypeFlags.StringLiteral | this.ts.TypeFlags.NumberLiteral))) {
          viable = false;
          break;
        }
        tags.push((t as tsTypes.StringLiteralType).value as string | number);
      }
      if (!viable) continue;
      if (new Set(tags.map((t) => `${t}`)).size !== tags.length) continue;
      const variants = members.map((member, i) => ({
        tag: tags[i]!,
        object: this.classify(member, `${nameHint}${pascal(String(tags[i]))}`),
      }));
      variants.sort((a, b) => (String(a.tag) < String(b.tag) ? -1 : String(a.tag) > String(b.tag) ? 1 : 0));
      return { kind: 'discriminatedUnion', name: nameHint, tagField, variants };
    }
    return null;
  }

  private classifyObject(type: tsTypes.Type, name: string): ObjectDef {
    const props = this.checker.getPropertiesOfType(type);
    const fields = props.map((sym) => this.classifyProperty(sym, name));
    fields.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    return { kind: 'object', name, fields };
  }

  private locationOf(symbol: tsTypes.Symbol): { file: string; line: number; column: number } | null {
    const declaration = symbol.valueDeclaration ?? symbol.declarations?.[0];
    if (!declaration) return null;
    const sourceFile = declaration.getSourceFile();
    const { line, character } = sourceFile.getLineAndCharacterOfPosition(declaration.getStart());
    return { file: sourceFile.fileName, line: line + 1, column: character + 1 };
  }

  private isOptional(symbol: tsTypes.Symbol, declared: tsTypes.Type): boolean {
    if ((symbol.flags & this.ts.SymbolFlags.Optional) !== 0) return true;
    const question = (symbol.declarations ?? []).some(
      (d) => 'questionToken' in d && d.questionToken !== undefined,
    );
    if (question) return true;
    if (declared.isUnion()) {
      return declared.types.some((t) => (t.flags & this.ts.TypeFlags.Undefined) !== 0);
    }
    return false;
  }

  private stripNullish(type: tsTypes.Type): { stripped: tsTypes.Type; nullable: boolean } {
    if (!type.isUnion()) return { stripped: type, nullable: false };
    const hasNull = type.types.some((t) => (t.flags & this.ts.TypeFlags.Null) !== 0);
    const hasUndefined = type.types.some((t) => (t.flags & this.ts.TypeFlags.Undefined) !== 0);
    if (!hasNull && !hasUndefined) return { stripped: type, nullable: false };
    const rest = type.types.filter(
      (t) => !(t.flags & (this.ts.TypeFlags.Null | this.ts.TypeFlags.Undefined)),
    );
    if (rest.length === 0) return { stripped: type, nullable: hasNull };
    if (rest.length === 1) return { stripped: rest[0]!, nullable: hasNull };
    // Multiple value members plus a nullish member cannot be rebuilt without
    // a public checker union API - surface it rather than guessing.
    throw fail('RPCDART0201', 'union with value members and nullish members cannot be decoded', 'restructure the union', {
      procedurePath: this.currentProcedure,
    });
  }

  private typeArgument(type: tsTypes.Type, index: number): tsTypes.Type | undefined {
    const args = (type as tsTypes.TypeReference).typeArguments;
    return args ? args[index] : undefined;
  }
}
