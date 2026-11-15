import { z } from 'zod';

export const SortDir = z.enum(['asc', 'desc']);
export type SortDir = z.infer<typeof SortDir>;

export const AddressSchema = z.object({
  city: z.string(),
  zip: z.string().optional(),
});
export type Address = z.infer<typeof AddressSchema>;

export const PaymentResultSchema = z.discriminatedUnion('type', [
  z.object({ type: z.literal('card'), last4: z.string() }),
  z.object({ type: z.literal('invoice'), invoiceId: z.string() }),
]);
export type PaymentResult = z.infer<typeof PaymentResultSchema>;

export const GetUserOutputSchema = z.object({
  id: z.string(),
  createdAt: z.date(),
  balance: z.bigint(),
  payment: PaymentResultSchema,
  sortHint: SortDir,
  metadata: z.record(z.string(), z.unknown()),
  nickname: z.string().optional().nullable(),
  address: AddressSchema.optional(),
});
export type GetUserOutput = z.infer<typeof GetUserOutputSchema>;

export const UpdateUserInputSchema = z.object({
  name: z.string().optional(),
  nickname: z.string().optional().nullable(),
  // z.input: string (wire), z.output: number (resolver) - proves the input/output split.
  charCount: z.string().transform((s) => s.length),
});
export type UpdateUserInput = z.input<typeof UpdateUserInputSchema>;

export const PostsListInputSchema = z.object({
  sort: SortDir,
  cursor: z.string().optional(),
});
export type PostsListInput = z.input<typeof PostsListInputSchema>;

export const PostOutputSchema = z.object({
  id: z.string(),
  title: z.string(),
  authorId: z.string(),
  published: z.boolean(),
});
export type PostOutput = z.infer<typeof PostOutputSchema>;

export const PostsListOutputSchema = z.object({
  items: z.array(PostOutputSchema),
  nextCursor: z.string().nullable(),
});
export type PostsListOutput = z.infer<typeof PostsListOutputSchema>;
