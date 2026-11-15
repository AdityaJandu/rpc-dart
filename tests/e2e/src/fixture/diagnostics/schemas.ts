import { z } from 'zod';

/** Unserializable: function in the output. */
export const BrokenDumpSchema = z.object({
  id: z.string(),
  callback: z.function(),
});
export type BrokenDump = z.infer<typeof BrokenDumpSchema>;

/** Unserializable: promise leaking through the output. */
export const BrokenJobSchema = z.object({
  id: z.string(),
  result: z.promise(z.string()),
});
export type BrokenJob = z.infer<typeof BrokenJobSchema>;

/** Non-discriminated union of objects (no shared literal tag). */
export const WeirdShapeSchema = z.union([
  z.object({ a: z.string() }),
  z.object({ b: z.number() }),
]);
export type WeirdShape = z.infer<typeof WeirdShapeSchema>;
