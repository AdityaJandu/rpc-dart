import { watch, type FSWatcher } from 'node:fs';
import { extractContract } from '@rpc-dart/trpc-adapter';
import { generate, type GenerateOptions } from './generate.js';

export interface WatchCycle {
  changed: boolean;
  durationMs: number;
  hash: string;
  written: number;
}

export interface WatchSessionOptions extends GenerateOptions {
  debounceMs?: number;
  onCycle?: (cycle: WatchCycle) => void;
  onError?: (error: Error) => void;
}

export class WatchSession {
  private readonly options: WatchSessionOptions;
  private readonly watchers: FSWatcher[] = [];
  private timer: ReturnType<typeof setTimeout> | null = null;
  private stopped = false;
  private running = false;
  private lastHash: string | null = null;

  constructor(options: WatchSessionOptions) {
    this.options = options;
  }

  start(): void {
    this.stopped = false;
    const watchDirs = new Set<string>([
      path.dirname(this.options.entryFile),
      path.dirname(this.options.tsconfigPath),
    ]);
    for (const dir of watchDirs) {
      try {
        const watcher = watch(dir, { recursive: true }, () => this.schedule());
        this.watchers.push(watcher);
      } catch {
        // Directory may not exist yet; the initial cycle still runs.
      }
    }
    void this.cycle();
  }

  stop(): void {
    this.stopped = true;
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    for (const watcher of this.watchers) {
      watcher.close();
    }
    this.watchers.length = 0;
  }

  private schedule(): void {
    if (this.stopped) return;
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.cycle();
    }, this.options.debounceMs ?? 300);
  }

  private async cycle(): Promise<void> {
    if (this.stopped || this.running) return;
    this.running = true;
    const started = Date.now();
    try {
      const { ir } = await extractContract({
        tsconfigPath: this.options.tsconfigPath,
        entryFile: this.options.entryFile,
        exportName: this.options.exportName,
        protocol: { kind: 'trpc', version: '11', transformer: this.options.transformer ?? 'superjson' },
        policies: this.options.policies,
      });
      if (this.lastHash !== null && ir.hash === this.lastHash) {
        this.options.onCycle?.({
          changed: false,
          durationMs: Date.now() - started,
          hash: ir.hash,
          written: 0,
        });
        return;
      }
      const result = await generate(this.options);
      this.lastHash = result.hash;
      this.options.onCycle?.({
        changed: result.wrote,
        durationMs: Date.now() - started,
        hash: result.hash,
        written: result.files.length,
      });
    } catch (error) {
      this.options.onError?.(error as Error);
    } finally {
      this.running = false;
    }
  }
}

import path from 'node:path';
