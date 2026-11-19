import { initTRPC } from '@trpc/server';
import superjson from 'superjson';
import { z } from 'zod';

// rpc-dart tRPC binary convention: Uint8Array <-> base64 ('Uint8Array'),
// File <-> {name, type, data} ('File'). File serialization is upload-only;
// downloads return Uint8Array because superjson serializers are synchronous.
superjson.registerCustom<Uint8Array, string>(
  {
    isApplicable: (v): v is Uint8Array => v instanceof Uint8Array,
    serialize: (v) => Buffer.from(v).toString('base64'),
    deserialize: (v) => new Uint8Array(Buffer.from(v, 'base64')),
  },
  'Uint8Array',
);

type FileWire = { name: string; type: string; data: string };

superjson.registerCustom<File, FileWire>(
  {
    isApplicable: (v): v is File => typeof File !== 'undefined' && v instanceof File,
    serialize: () => {
      throw new Error('File outputs are not supported on the tRPC wire; return Uint8Array');
    },
    deserialize: (v) => new File([Buffer.from(v.data, 'base64')], v.name, { type: v.type }),
  },
  'File',
);

const t = initTRPC.create({ transformer: superjson });

export const binaryRouter = t.router({
  bytes: t.router({
    echo: t.procedure
      .input(z.custom<Uint8Array>())
      .output(z.custom<Uint8Array>())
      .mutation(({ input }) => input),
  }),
  files: t.router({
    upload: t.procedure
      .input(z.object({ file: z.custom<File>() }))
      .mutation(({ input }) => ({ name: input.file.name, size: input.file.size })),
  }),
});