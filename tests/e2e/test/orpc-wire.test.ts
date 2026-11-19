import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { startOrpcFixtureServer, type OrpcFixtureServer } from '../src/orpc-server.js';

let server: OrpcFixtureServer;
let base: string;

beforeAll(async () => {
  server = await startOrpcFixtureServer();
  base = `http://127.0.0.1:${server.port}/rpc`;
}, 30000);

afterAll(async () => {
  await server?.close();
});

describe('oRPC wire conformance (live Fastify RPCHandler)', () => {
  it('routes dotted paths to slash URLs and returns numeric-tag envelopes', async () => {
    const response = await fetch(`${base}/planet/create`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ json: { name: 'Venus' } }),
    });
    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      json: { id: number; name: string; discoveredAt: string; mass: string };
      meta: Array<[number, ...Array<string | number>]>;
    };
    expect(body.json.name).toBe('Venus');
    expect(body.json.mass).toBe('1');
    expect(body.meta).toContainEqual([0, 'mass']);
    expect(body.meta).toContainEqual([1, 'discoveredAt']);
  });

  it('accepts GET queries with ?data= envelopes', async () => {
    const url = `${base}/planet/find?data=${encodeURIComponent(JSON.stringify({ json: { id: 1 } }))}`;
    const response = await fetch(url);
    expect(response.status).toBe(200);
    const body = (await response.json()) as { json: { name: string } };
    expect(body.json.name).toBe('Earth');
  });

  it('returns ORPCError bodies with defined/code/status/message/data', async () => {
    const response = await fetch(`${base}/planet/find?data=${encodeURIComponent(JSON.stringify({ json: { id: 999 } }))}`);
    expect(response.status).toBe(404);
    const body = (await response.json()) as {
      json: { defined: boolean; code: string; status: number; message: string; data: { id: number } };
    };
    expect(body.json.defined).toBe(true);
    expect(body.json.code).toBe('NOT_FOUND');
    expect(body.json.status).toBe(404);
    expect(body.json.data.id).toBe(999);
  });

  it('accepts multipart uploads with maps inside the data field', async () => {
    const form = new FormData();
    form.set(
      'data',
      JSON.stringify({
        json: { file: {}, note: 'hello' },
        maps: [['file']],
      }),
    );
    form.set('0', new Blob([new Uint8Array([1, 2, 3])], { type: 'image/png' }), 'a.png');
    const response = await fetch(`${base}/uploads/avatar`, { method: 'POST', body: form });
    expect(response.status).toBe(200);
    const body = (await response.json()) as { json: { name: string; size: number; note: string } };
    expect(body.json).toEqual({ name: 'a.png', size: 3, note: 'hello' });
  });

  it('returns root File outputs as multipart with an empty-path map (1.16.3 wire)', async () => {
    const response = await fetch(`${base}/files/download`);
    expect(response.status).toBe(200);
    expect(response.headers.get('content-type')).toContain('multipart/form-data');
    const form = await response.formData();
    const data = JSON.parse(String(form.get('data'))) as { maps: string[][] };
    expect(data.maps).toEqual([[]]);
    const part = form.get('0') as File;
    expect(part.name).toBe('earth.png');
    expect(part.type).toBe('image/png');
    expect(new Uint8Array(await part.arrayBuffer())).toEqual(new Uint8Array([10, 20, 30, 40]));
  });

  it('returns ReadableStream outputs as headerless binary passthrough', async () => {
    const response = await fetch(`${base}/files/stream`);
    expect(response.status).toBe(200);
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(new Uint8Array([1, 2, 3]));
  });

  it('returns nested-file outputs as multipart responses', async () => {
    const response = await fetch(`${base}/files/bundle`);
    expect(response.status).toBe(200);
    expect(response.headers.get('content-type')).toContain('multipart/form-data');
    const form = await response.formData();
    const data = JSON.parse(String(form.get('data'))) as {
      json: { name: string; avatar: Record<string, never> };
      maps: string[][];
    };
    expect(data.json.name).toBe('Earth');
    expect(data.maps).toEqual([['avatar']]);
    const part = form.get('0') as Blob;
    expect(part.type).toBe('image/png');
    expect(new Uint8Array(await part.arrayBuffer())).toEqual(new Uint8Array([9]));
  });

  it('streams event iterators as SSE message/done frames with ids', async () => {
    const response = await fetch(`${base}/streams/ticks`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ json: { count: 3 } }),
    });
    expect(response.status).toBe(200);
    expect(response.headers.get('content-type')).toContain('text/event-stream');
    const text = await response.text();
    expect(text).toContain('event: message');
    expect(text).toContain('id: 0');
    expect(text).toContain('id: 2');
    expect(text).toContain('event: done');
    const messages = text
      .split('\n\n')
      .filter((frame) => frame.includes('event: message'))
      .map((frame) => {
        const dataLine = frame.split('\n').find((line) => line.startsWith('data: '))!;
        return JSON.parse(dataLine.slice(6)) as { json: { tick: number }; meta: unknown[] };
      });
    expect(messages.map((m) => m.json.tick)).toEqual([0, 1, 2]);
    expect(messages[0]!.meta).toContainEqual([1, 'at']);
  });

  it('replays event iterators from last-event-id', async () => {
    const response = await fetch(`${base}/streams/ticks`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'last-event-id': '1' },
      body: JSON.stringify({ json: { count: 3 } }),
    });
    const text = await response.text();
    expect(text).not.toContain('id: 0');
    expect(text).not.toContain('id: 1');
    expect(text).toContain('id: 2');
  });

  it('rejects unauthorized calls with a defined UNAUTHORIZED error', async () => {
    const denied = await fetch(`${base}/secure/me`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{}',
    });
    expect(denied.status).toBe(401);
    const body = (await denied.json()) as { json: { code: string; defined: boolean } };
    expect(body.json.code).toBe('UNAUTHORIZED');
    expect(body.json.defined).toBe(true);

    const allowed = await fetch(`${base}/secure/me`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: 'Bearer u1' },
      body: '{}',
    });
    expect(allowed.status).toBe(200);
    expect(((await allowed.json()) as { json: { id: string } }).json.id).toBe('u1');
  });
});