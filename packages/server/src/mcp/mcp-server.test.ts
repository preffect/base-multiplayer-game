import Fastify, { type FastifyInstance } from 'fastify';
import { afterEach, describe, expect, it } from 'vitest';
import {
  DEBUG_MCP_SWITCHED_OFF,
  DEBUG_MCP_SWITCHED_ON,
  MCP_INITIALIZE_REQUEST,
  MCP_POST_HEADERS,
  buildEmptyDebugContext,
} from '../testing/debug-context-builders.js';
import { DEBUG_MCP_PATH, isDebugMcpEnabled, mountDebugMcpWhenEnabled } from './mcp-server.js';

const HTTP_OK = 200;
const HTTP_FORBIDDEN = 403;
const HTTP_NOT_FOUND = 404;
const HTTP_METHOD_NOT_ALLOWED = 405;

describe('mcp/mcp-server gate', () => {
  let server: FastifyInstance | undefined;

  afterEach(async () => {
    await server?.close();
    server = undefined;
  });

  function serverWith(environment: NodeJS.ProcessEnv): FastifyInstance {
    server = Fastify();
    mountDebugMcpWhenEnabled(server, buildEmptyDebugContext(), environment);
    return server;
  }

  function postFrom(app: FastifyInstance, headers: Record<string, string>) {
    return app.inject({
      method: 'POST',
      url: DEBUG_MCP_PATH,
      headers: { ...MCP_POST_HEADERS, ...headers },
      payload: MCP_INITIALIZE_REQUEST,
    });
  }

  it('is on only for exactly DEBUG_MCP=1', () => {
    expect(isDebugMcpEnabled(DEBUG_MCP_SWITCHED_ON)).toBe(true);
    for (const environment of DEBUG_MCP_SWITCHED_OFF) expect(isDebugMcpEnabled(environment)).toBe(false);
  });

  it.each(DEBUG_MCP_SWITCHED_OFF)('is not mounted with the switch at %o', async (environment) => {
    const response = await postFrom(serverWith(environment), { host: 'localhost' });
    expect(response.statusCode).toBe(HTTP_NOT_FOUND);
  });

  it('answers a loopback POST when the switch is on', async () => {
    const response = await postFrom(serverWith(DEBUG_MCP_SWITCHED_ON), { host: 'localhost:4400' });
    expect(response.statusCode).toBe(HTTP_OK);
    expect(response.body).toContain('"serverInfo"');
  });

  it.each<Record<string, string>>([
    { host: 'debug.example.com' },
    { host: 'localhost.example.com' },
    { host: 'localhost', origin: 'http://attacker.example' },
  ])('refuses %o', async (headers) => {
    const response = await postFrom(serverWith(DEBUG_MCP_SWITCHED_ON), headers);
    expect(response.statusCode).toBe(HTTP_FORBIDDEN);
  });

  it.each(['GET', 'DELETE'] as const)('answers %s with 405 and Allow: POST', async (method) => {
    const response = await serverWith(DEBUG_MCP_SWITCHED_ON).inject({
      method,
      url: DEBUG_MCP_PATH,
      headers: { host: 'localhost' },
    });
    expect(response.statusCode).toBe(HTTP_METHOD_NOT_ALLOWED);
    expect(response.headers.allow).toBe('POST');
  });
});
