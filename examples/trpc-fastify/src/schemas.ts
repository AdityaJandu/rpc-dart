import { z } from 'zod';

export const SortDir = z.enum(['asc', 'desc']);
export type SortDir = z.infer<typeof SortDir>;

export const ReceiptSchema = z.discriminatedUnion('kind', [
  z.object({
    kind: z.literal('card'),
    last4: z.string(),
    authorizedAt: z.date(),
  }),
  z.object({
    kind: z.literal('invoice'),
    invoiceId: z.string(),
    dueInDays: z.number().int(),
  }),
]);
export type Receipt = z.infer<typeof ReceiptSchema>;

export interface User {
  id: string;
  name: string;
  nickname: string | null;
  createdAt: Date;
  balance: bigint;
  receipt: Receipt;
}

export const UserSchema = z.object({
  id: z.string(),
  name: z.string(),
  nickname: z.string().optional().nullable(),
  createdAt: z.date(),
  balance: z.bigint(),
  receipt: ReceiptSchema,
});

export const UpdateUserInputSchema = z.object({
  name: z.string().optional(),
  nickname: z.string().optional().nullable(),
  promoCode: z.string().transform((s) => s.trim().toUpperCase()),
});
export type UpdateUserInput = z.input<typeof UpdateUserInputSchema>;

export const ListPostsInputSchema = z.object({
  sort: SortDir,
  cursor: z.string().optional(),
});
export type ListPostsInput = z.input<typeof ListPostsInputSchema>;

export const PostSchema = z.object({
  id: z.string(),
  title: z.string(),
  score: z.number(),
});
export type Post = z.infer<typeof PostSchema>;

export const ListPostsOutputSchema = z.object({
  items: z.array(PostSchema),
  nextCursor: z.string().nullable(),
});
export type ListPostsOutput = z.infer<typeof ListPostsOutputSchema>;
