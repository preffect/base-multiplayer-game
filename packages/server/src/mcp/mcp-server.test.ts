import Fastify, { type FastifyInstance } from 'fastify';
import { afterEach, describe, expect, it } from 'vitest';
import { buildEmptyDebugContext } from '../testing/debug-context-builders.js';
import {
  DEBUG_MCP_SWITCHED_OFF,
  DEBUG_MCP_SWITCHED_ON,
  LOOPBACK_HOST_WITH_PORT,
  MCP_POST_HEADERS,
} from '../testing/debug-mcp-builders.js';
import { DEBUG_MCP_PATH } from './debug-mcp-http.js';
import { HTTP_NOT_FOUND, HTTP_OK } from './http-status.js';
import { mountDebugMcp, registerMcpEndpoint } from './mcp-server.js';

const TOOLS_LIST_REQUEST = { jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} };

describe('mcp/mcp-server: the game mount', () => {
  let app: FastifyInstance | undefined;

  afterEach(async () => {
    await app?.close();
    app = undefined;
  });

  function listTools(target: FastifyInstance) {
    return target.inject({
      method: 'POST',
      url: DEBUG_MCP_PATH,
      headers: { ...MCP_POST_HEADERS, host: LOOPBACK_HOST_WITH_PORT },
      payload: TOOLS_LIST_REQUEST,
    });
  }

  it.each([
    ['mountDebugMcp', mountDebugMcp],
    ['the deprecated registerMcpEndpoint', registerMcpEndpoint],
  ])('%s is gated by the switch', async (_name, mount) => {
    for (const environment of DEBUG_MCP_SWITCHED_OFF) {
      app = Fastify();
      expect(mount(app, buildEmptyDebugContext(), environment)).toBe(false);
      expect((await listTools(app)).statusCode).toBe(HTTP_NOT_FOUND);
      await app.close();
    }
    app = Fastify();
    expect(mount(app, buildEmptyDebugContext(), DEBUG_MCP_SWITCHED_ON)).toBe(true);
    const response = await listTools(app);
    expect(response.statusCode).toBe(HTTP_OK);
    expect(response.body).toContain('debug_list_games');
  });
});
