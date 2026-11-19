import { initTRPC } from '@trpc/server';
import superjson from 'superjson';
import { z } from 'zod';

const t = initTRPC.create({ transformer: superjson });

// Node's Buffer without pulling @types/node into the DOM-lib fixture.
type Buffer = Uint8Array;
declare const Buffer: { from(s: string): Buffer };

export const appRouter = t.router({
  bytes: t.router({
    fromUint8Array: t.procedure.output(z.custom<Uint8Array>()).query(() => new Uint8Array([1, 2, 3])),
    fromArrayBuffer: t.procedure.output(z.custom<ArrayBuffer>()).query(() => new ArrayBuffer(8)),
    fromBuffer: t.procedure.output(z.custom<Buffer>()).query(() => Buffer.from('abc')),
  }),
  files: t.router({
    fromFile: t.procedure.output(z.custom<File>()).query(() => new File(['x'], 'a.txt')),
    fromBlob: t.procedure.output(z.custom<Blob>()).query(() => new Blob(['x'])),
    upload: t.procedure
      .input(z.object({ avatar: z.custom<File>(), payload: z.custom<Uint8Array>() }))
      .mutation(({ input }) => ({ size: input.payload.byteLength, name: input.avatar.name })),
  }),
  streams: t.router({
    download: t.procedure.output(z.custom<ReadableStream<Uint8Array>>()).query(() => new ReadableStream<Uint8Array>()),
  }),
});

export type AppRouter = typeof appRouter;