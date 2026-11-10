import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import Fastify, { type FastifyInstance } from 'fastify';
import { afterEach, describe, expect, it } from 'vitest';
import { CLIENT_DIR_VARIABLE, isServerPath, serveClientFiles } from './client-files.js';

const PAGE = '<!doctype html><title>game</title>';
const SCRIPT = 'console.log("game");';

function builtClient(): string {
  const root = mkdtempSync(join(tmpdir(), 'client-files-'));
  writeFileSync(join(root, 'index.html'), PAGE);
  mkdirSync(join(root, 'assets'));
  writeFileSync(join(root, 'assets', 'main.js'), SCRIPT);
  return root;
}

describe('platform/client-files', () => {
  let server: FastifyInstance;

  async function serverWith(environment: NodeJS.ProcessEnv): Promise<{ served: boolean }> {
    server = Fastify();
    server.get('/api/health', async () => ({ status: 'ok' }));
    const served = await serveClientFiles(server, environment);
    await server.ready();
    return { served };
  }

  afterEach(async () => {
    await server.close();
  });

  it('serves nothing when the client folder is not set, as in dev', async () => {
    const { served } = await serverWith({});
    expect(served).toBe(false);
    expect((await server.inject({ url: '/' })).statusCode).toBe(404);
  });

  it('serves the page, its files, and the page again for a client-side route', async () => {
    const { served } = await serverWith({ [CLIENT_DIR_VARIABLE]: builtClient() });
    expect(served).toBe(true);
    expect((await server.inject({ url: '/' })).body).toBe(PAGE);
    expect((await server.inject({ url: '/assets/main.js' })).body).toBe(SCRIPT);
    const route = await server.inject({ url: '/lobby/abc?x=1' });
    expect(route.statusCode).toBe(200);
    expect(route.body).toBe(PAGE);
  });

  it('leaves the server its own paths', async () => {
    await serverWith({ [CLIENT_DIR_VARIABLE]: builtClient() });
    expect((await server.inject({ url: '/api/health' })).json()).toEqual({ status: 'ok' });
    for (const url of ['/api/unknown', '/ws', '/ws/x', '/debug-mcp', '/mcp', '/mcp/tools']) {
      const response = await server.inject({ url });
      expect(response.statusCode, url).toBe(404);
      expect(response.body, url).not.toContain('<title>');
    }
  });

  it('gives only GETs the page', async () => {
    await serverWith({ [CLIENT_DIR_VARIABLE]: builtClient() });
    expect((await server.inject({ method: 'POST', url: '/lobby' })).statusCode).toBe(404);
  });

  it('serves nothing outside the client folder', async () => {
    await serverWith({ [CLIENT_DIR_VARIABLE]: builtClient() });
    const response = await server.inject({ url: '/../../etc/passwd' });
    expect(response.body).not.toContain('root:');
  });

  it.each([
    ['/api', true],
    ['/api/x', true],
    ['/ws', true],
    ['/mcp', true],
    ['/debug-mcp', true],
    ['/apiary', false],
    ['/wsx', false],
    ['/', false],
    ['/lobby', false],
  ])('knows %s is the server’s own: %s', (path, own) => expect(isServerPath(path)).toBe(own));
});
