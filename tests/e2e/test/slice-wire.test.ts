import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { startFixtureServer, type FixtureServer } from '../src/fixture-server.js';

let server: FixtureServer;

beforeAll(async () => {
  server = await startFixtureServer();
});

afterAll(async () => {
  await server.close();
});

const authHeaders = { authorization: 'Bearer u1' };

function url(path: string): string {
  return `http://127.0.0.1:${server.port}/trpc/${path}`;
}

function enc(value: unknown): string {
  return encodeURIComponent(JSON.stringify(value));
}

describe('fixture server wire envelope', () => {
  it('GET query returns a superjson-wrapped result envelope', async () => {
    const res = await fetch(`${url('user.getById')}?input=${enc({ json: { id: 'u1' } })}`, {
      headers: authHeaders,
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body).toEqual({
      result: {
        data: {
          json: {
            id: 'u1',
            createdAt: '2026-01-15T10:00:00.000Z',
            balance: '123',
            payment: { type: 'card', last4: '4242' },
            sortHint: 'asc',
            metadata: { env: 'test', retries: 3 },
            nickname: null,
            address: { city: 'Delft' },
          },
          meta: { v: 1, values: { createdAt: ['Date'], balance: ['bigint'] } },
        },
      },
    });
  });

  it('GET without credentials returns an UNAUTHORIZED error envelope', async () => {
    const res = await fetch(`${url('user.getById')}?input=${enc({ json: { id: 'u1' } })}`);
    expect(res.status).toBe(401);
    const body = (await res.json()) as {
      error: { json: { code: number; message: string; data: { code: string; httpStatus: number } } };
    };
    expect(body.error.json.code).toBe(-32001);
    expect(body.error.json.data.code).toBe('UNAUTHORIZED');
    expect(typeof body.error.json.message).toBe('string');
    expect(body.error.json.data.httpStatus).toBe(401);
  });

  it('POST mutation accepts explicit null and absent optional-nullable fields', async () => {
    const post = (input: unknown) =>
      fetch(url('user.update'), {
        method: 'POST',
        headers: { ...authHeaders, 'content-type': 'application/json' },
        body: JSON.stringify({ json: input }),
      });

    const explicitNull = await post({ name: 'Ada', nickname: null, charCount: 'abcde' });
    expect(explicitNull.status).toBe(200);
    const explicitNullBody = (await explicitNull.json()) as { result: { data: { json: { id: string } } } };
    expect(explicitNullBody.result.data.json.id).toBe('u1');

    const absent = await post({ charCount: 'abcde' });
    expect(absent.status).toBe(200);
    const absentBody = (await absent.json()) as { result: { data: { json: { id: string } } } };
    expect(absentBody.result.data.json.id).toBe('u1');
  });

  it('rejects a mutation whose transform input has the wrong wire type', async () => {
    // charCount is z.string().transform(...) on the input side: the wire type is string.
    const res = await fetch(url('user.update'), {
      method: 'POST',
      headers: { ...authHeaders, 'content-type': 'application/json' },
      body: JSON.stringify({ json: { charCount: 5 } }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as {
      error: { json: { data: { code: string } } };
    };
    expect(body.error.json.data.code).toBe('BAD_REQUEST');
  });

  it('batched GET preserves request order (index-aligned array)', async () => {
    const input = { '1': { json: { sort: 'asc' } } };
    const res = await fetch(`${url('user.me,posts.list')}?batch=1&input=${enc(input)}`);
    expect(res.status).toBe(200);
    const body = (await res.json()) as Array<{ result: { data: { json: Record<string, unknown> } } }>;
    expect(Array.isArray(body)).toBe(true);
    expect(body).toHaveLength(2);
    expect(body[0]!.result.data.json.id).toBe('u1');
    expect(body[1]!.result.data.json.items).toHaveLength(2);
    expect(body[1]!.result.data.json.nextCursor).toBeNull();
  });
});
