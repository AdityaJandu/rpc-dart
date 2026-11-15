import type { JsonValue } from './ir.js';

/** Stable diagnostic codes. */
export type DiagnosticCode =
  | 'RPCDART0101' // config invalid
  | 'RPCDART0102' // entry export not found / not a router
  | 'RPCDART0103' // tsconfig missing or aliases unresolved
  | 'RPCDART0104' // tRPC version unknown
  | 'RPCDART0105' // harness type-check failed
  | 'RPCDART0106' // procedure type extraction failed
  | 'RPCDART0107' // dart outDir missing
  | 'RPCDART0108' // runtime probe degraded
  | 'RPCDART0201' // unserializable type
  | 'RPCDART0202' // non-discriminated object union
  | 'RPCDART0203' // unmappable key type
  | 'RPCDART0204'; // unknown-policy collision

export type DiagnosticSeverity = 'error' | 'warning' | 'info';

export interface RpcDartDiagnostic {
  code: DiagnosticCode;
  severity: DiagnosticSeverity;
  message: string;
  procedurePath?: string;
  file?: string;
  line?: number;
  column?: number;
  hint?: string;
  data?: Record<string, JsonValue>;
}

export class ExtractionFailure extends Error {
  constructor(readonly diagnostics: RpcDartDiagnostic[]) {
    super(
      `extraction failed with ${diagnostics.length} diagnostic(s): ` +
        diagnostics.map((d) => `${d.code} ${d.message}`).join('; '),
    );
    this.name = 'ExtractionFailure';
  }
}
