import { eventIterator, os } from '@orpc/server';
import { z } from 'zod';

export const badRouter = os.router({
  streamInput: os.input(eventIterator(z.object({ n: z.number() }))).handler(() => 'ok'),
  fine: os.handler(() => 1),
});