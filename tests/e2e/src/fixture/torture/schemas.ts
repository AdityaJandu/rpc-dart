import { z } from 'zod';

export const SortDir = z.enum(['asc', 'desc']);
export type SortDir = z.infer<typeof SortDir>;

/** Recursive type: explicit interface annotation avoids implicit-any cycles. */
export interface Category {
  id: string;
  name: string;
  children: Category[];
}
export const CategorySchema: z.ZodType<Category> = z.object({
  id: z.string(),
  name: z.string(),
  children: z.array(z.lazy(() => CategorySchema)),
});

export interface Post {
  id: string;
  title: string;
  score: number;
}
export const PostSchema = z.object({
  id: z.string(),
  title: z.string(),
  score: z.number(),
});

/** Record<string, Post[]> -> Map<String, List<Post>>. */
export const PostsByTagSchema = z.record(z.string(), z.array(PostSchema));
export type PostsByTag = { [tag: string]: Post[] };

/** Enum-keyed record: zod infers a concrete object with per-key fields. */
export const TagCountsSchema = z.record(SortDir, z.number());
export type TagCounts = { asc?: number; desc?: number };

/** Fixed-length tuple -> Dart positional record. */
export const PointSchema = z.tuple([z.string(), z.number()]);
export type Point = [string, number];

/** Set<string> -> Set<String> via SuperJSON annotation. */
export const UniqueTagsSchema = z.set(z.string());
export type UniqueTags = z.infer<typeof UniqueTagsSchema>;

/** Map<string, number> -> Map<String, double> via SuperJSON annotation. */
export const AttributeMapSchema = z.map(z.string(), z.number());
export type AttributeMap = z.infer<typeof AttributeMapSchema>;

/** Numeric literal union -> enum with numeric raw values. */
export const SchemaVersion = z.union([z.literal(1), z.literal(2), z.literal(3)]);
export type SchemaVersion = z.infer<typeof SchemaVersion>;

/** Branded string -> underlying primitive. */
export const UserIdSchema = z.string().brand<'UserId'>();
export type UserId = z.infer<typeof UserIdSchema>;

export interface TortureInput {
  category: Category;
  postsByTag: PostsByTag;
  tagCounts: { asc?: number; desc?: number };
  origin: Point;
  uniqueTags: UniqueTags;
  attributes: AttributeMap;
  version: SchemaVersion;
  ownerId: string;
  sort: SortDir;
}
export const TortureInputSchema: z.ZodType<TortureInput> = z.object({
  category: CategorySchema,
  postsByTag: PostsByTagSchema,
  tagCounts: TagCountsSchema,
  origin: PointSchema,
  uniqueTags: UniqueTagsSchema,
  attributes: AttributeMapSchema,
  version: SchemaVersion,
  ownerId: UserIdSchema,
  sort: SortDir,
});

export interface TortureOutput {
  category: Category;
  postsByTag: PostsByTag;
  tagCounts: { asc?: number; desc?: number };
  origin: Point;
  uniqueTags: UniqueTags;
  attributes: AttributeMap;
  version: SchemaVersion;
  ownerId: UserId;
  sort: SortDir;
}
export const TortureOutputSchema: z.ZodType<TortureOutput, z.ZodTypeDef, TortureInput> = z.object({
  category: CategorySchema,
  postsByTag: PostsByTagSchema,
  tagCounts: TagCountsSchema,
  origin: PointSchema,
  uniqueTags: UniqueTagsSchema,
  attributes: AttributeMapSchema,
  version: SchemaVersion,
  ownerId: UserIdSchema,
  sort: SortDir,
});
