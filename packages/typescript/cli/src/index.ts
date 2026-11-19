export { generate, type GenerateOptions, type GenerateResult } from './commands/generate.js';
export { selectAdapter, type Adapter, type AdapterChoice, type AdapterExtractOptions } from './adapter.js';
export { checkContract, type CheckResult } from './commands/check.js';
export {
  diffContract,
  diffIr,
  type DiffEntry,
  type DiffOptions,
  type DiffResult,
} from './commands/diff.js';
export { cleanGenerated, type CleanResult } from './commands/clean.js';
export { doctorChecks, type DoctorCheck, type DoctorOptions } from './commands/doctor.js';
export { initWorkspace, type InitOptions, type InitResult } from './commands/init.js';
export { WatchSession, type WatchCycle, type WatchSessionOptions } from './commands/watch.js';
export {
  ConfigNotFoundError,
  defineConfig,
  findConfigFile,
  loadConfigFileAsync as loadConfig,
  resolveTargets,
  type RpcDartConfig,
  type RpcDartTarget,
} from './config.js';
