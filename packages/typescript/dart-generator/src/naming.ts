const DART_RESERVED = new Set([
  'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case', 'catch', 'class',
  'const', 'continue', 'covariant', 'default', 'deferred', 'do', 'dynamic', 'else', 'enum',
  'export', 'extends', 'extension', 'external', 'factory', 'false', 'final', 'finally', 'for',
  'function', 'get', 'hide', 'if', 'implements', 'import', 'in', 'interface', 'is', 'late',
  'library', 'mixin', 'new', 'null', 'on', 'operator', 'part', 'required', 'rethrow', 'return',
  'sealed', 'set', 'show', 'static', 'super', 'switch', 'sync', 'this', 'throw', 'true', 'try',
  'type', 'typedef', 'var', 'void', 'when', 'while', 'with', 'yield',
]);

export function dartPascal(input: string): string {
  return input
    .split(/[._\-\s]/)
    .filter((s) => s.length > 0)
    .map((s) => s.charAt(0).toUpperCase() + s.slice(1))
    .join('');
}

export function dartSnake(className: string): string {
  return className
    .replace(/([a-z0-9])([A-Z])/g, '$1_$2')
    .replace(/([A-Z]+)([A-Z][a-z])/g, '$1_$2')
    .toLowerCase();
}

export function fieldName(name: string): string {
  return DART_RESERVED.has(name) ? `${name}_` : name;
}

export function procClassName(path: string): string {
  return `${dartPascal(path)}Proc`;
}

export function routerClassName(segment: string): string {
  return `${dartPascal(segment)}Router`;
}

export function modelFileName(className: string): string {
  return `${dartSnake(className)}.dart`;
}

export function procedureFileName(path: string): string {
  return `${dartSnake(dartPascal(path))}.dart`;
}
