import { z } from 'zod';

export const StatusSchema = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('up'), since: z.date() }),
  z.object({ kind: z.literal('down'), reason: z.string() }),
]);
export type StatusUpdate = z.infer<typeof StatusSchema>;

export interface UserEvent {
  userId: string;
  action: string;
  at: Date;
}

export const ActivityInputSchema = z.object({
  channelId: z.string(),
  lastEventId: z.string().nullish(),
});
