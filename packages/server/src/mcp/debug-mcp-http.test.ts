import Fastify, { type FastifyInstance, type InjectOptions } from 'fastify';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  BRIDGE_GATEWAY_ADDRESS,
  DEBUG_MCP_SWITCHED_OFF,
  DEBUG_MCP_SWITCHED_ON,
  LAN_PEER_ADDRESS,
  LOOPBACK_HOST_WITH_PORT,
  LOOPBACK_ORIGIN,
  MCP_INITIALIZE_REQUEST,
  MCP_POST_HEADERS,
  createProbeDebugServer,
} from '../testing/debug-mcp-builders.js';
import {
  DEBUG_MCP_PATH,
  JSON_RPC_INTERNAL_ERROR,
  JSON_RPC_SERVER_ERROR,
  type DebugMcpServerFactory,
  isDebugMcpEnabled,
  mountDebugMcpHttp,
} from './debug-mcp-http.js';
import {
  HTTP_FORBIDDEN,
  HTTP_INTERNAL_SERVER_ERROR,
  HTTP_METHOD_NOT_ALLOWED,
  HTTP_NOT_FOUND,
  HTTP_OK,
} from './http-status.js';

const REFUSED_HEADERS: Record<string, string>[] = [
  { host: 'debug.example.com' },
  { host: 'localhost.example.com' },
  { host: LOOPBACK_HOST_WITH_PORT, origin: 'http://attacker.example' },
];

/** A Fastify whose warnings and errors are kept as parsed log lines. */
function recordingFastify(): { app: FastifyInstance; logLines: { level: number; msg: string }[] } {
  const logLines: { level: number; msg: string }[] = [];
  const app = Fastify({
    logger: { level: 'warn', stream: { write: (line: string) => logLines.push(JSON.parse(line)) } },
  });
  return { app, logLines };
}

describe('mcp/debug-mcp-http', () => {
  let app: FastifyInstance | undefined;

  afterEach(async () => {
    await app?.close();
    app = undefined;
    vi.restoreAllMocks();
  });

  function mounted(environment: NodeJS.ProcessEnv, createServer: DebugMcpServerFactory = createProbeDebugServer) {
    const recording = recordingFastify();
    app = recording.app;
    mountDebugMcpHttp(app, createServer, environment);
    return recording;
  }

  function post(target: FastifyInstance, extra: Partial<InjectOptions> = {}, headers: Record<string, string> = {}) {
    return target.inject({
      method: 'POST',
      url: DEBUG_MCP_PATH,
      headers: { ...MCP_POST_HEADERS, host: LOOPBACK_HOST_WITH_PORT, ...headers },
      payload: MCP_INITIALIZE_REQUEST,
      ...extra,
    });
  }

  it('is on only for exactly DEBUG_MCP=1', () => {
    expect(isDebugMcpEnabled(DEBUG_MCP_SWITCHED_ON)).toBe(true);
    for (const environment of DEBUG_MCP_SWITCHED_OFF) expect(isDebugMcpEnabled(environment)).toBe(false);
  });

  it.each(DEBUG_MCP_SWITCHED_OFF)(
    'mounts nothing, and builds no server, with the switch at %o',
    async (environment) => {
      const createServer = vi.fn(createProbeDebugServer);
      const { app: target } = mounted(environment, createServer);
      expect((await post(target)).statusCode).toBe(HTTP_NOT_FOUND);
      expect(createServer).not.toHaveBeenCalled();
    },
  );

  it('answers a loopback POST, and one with a loopback Origin', async () => {
    const { app: target } = mounted(DEBUG_MCP_SWITCHED_ON);
    const response = await post(target);
    expect(response.statusCode).toBe(HTTP_OK);
    expect(response.body).toContain('"serverInfo"');
    expect((await post(target, {}, { origin: LOOPBACK_ORIGIN })).statusCode).toBe(HTTP_OK);
  });

  it.each(REFUSED_HEADERS)('refuses %o with a JSON-RPC 403', async (headers) => {
    const response = await post(mounted(DEBUG_MCP_SWITCHED_ON).app, {}, headers);
    expect(response.statusCode).toBe(HTTP_FORBIDDEN);
    expect(response.json()).toMatchObject({ jsonrpc: '2.0', error: { code: JSON_RPC_SERVER_ERROR }, id: null });
  });

  it.each([LAN_PEER_ADDRESS, BRIDGE_GATEWAY_ADDRESS])(
    'refuses the peer %s even with a forged loopback Host',
    async (remoteAddress) => {
      const response = await post(mounted(DEBUG_MCP_SWITCHED_ON).app, { remoteAddress });
      expect(response.statusCode).toBe(HTTP_FORBIDDEN);
    },
  );

  it.each(['GET', 'DELETE'] as const)('answers a loopback %s with 405 and Allow: POST', async (method) => {
    const response = await mounted(DEBUG_MCP_SWITCHED_ON).app.inject({
      method,
      url: DEBUG_MCP_PATH,
      headers: { host: LOOPBACK_HOST_WITH_PORT },
    });
    expect(response.statusCode).toBe(HTTP_METHOD_NOT_ALLOWED);
    expect(response.headers.allow).toBe('POST');
  });

  it.each(['GET', 'DELETE'] as const)(
    'refuses a %s from a foreign Host with 403 before the method check',
    async (method) => {
      const response = await mounted(DEBUG_MCP_SWITCHED_ON).app.inject({
        method,
        url: DEBUG_MCP_PATH,
        headers: { host: 'debug.example.com' },
      });
      expect(response.statusCode).toBe(HTTP_FORBIDDEN);
    },
  );

  it('fails at mount, not on each call, when the server cannot be built', () => {
    const brokenFactory = () => {
      throw new Error('duplicate tool');
    };
    expect(() => mountDebugMcpHttp(Fastify(), brokenFactory, DEBUG_MCP_SWITCHED_ON)).toThrow('duplicate tool');
  });

  it('answers a JSON-RPC 500 when the request fails after the hijack', async () => {
    const failingConnect = () => {
      const server = createProbeDebugServer();
      vi.spyOn(server, 'connect').mockRejectedValue(new Error('connect failed'));
      return server;
    };
    const { app: target, logLines } = mounted(DEBUG_MCP_SWITCHED_ON, failingConnect);
    const response = await post(target);
    expect(response.statusCode).toBe(HTTP_INTERNAL_SERVER_ERROR);
    expect(response.json()).toMatchObject({ error: { code: JSON_RPC_INTERNAL_ERROR } });
    expect(logLines.map((line) => line.msg)).toContain('debug MCP request failed');
  });

  it('cuts the connection when the request fails after its headers were sent', async () => {
    vi.spyOn(StreamableHTTPServerTransport.prototype, 'handleRequest').mockImplementation(
      async (_request, response) => {
        response.writeHead(HTTP_OK);
        throw new Error('failed mid-stream');
      },
    );
    const { app: target, logLines } = mounted(DEBUG_MCP_SWITCHED_ON);
    // The 200 header is already out, so no 500 can follow: the response is cut (inject may reject).
    const statusCode = await post(target).then(
      (response) => response.statusCode,
      () => undefined,
    );
    expect(statusCode).not.toBe(HTTP_INTERNAL_SERVER_ERROR);
    expect(logLines.map((line) => line.msg)).toContain('debug MCP request failed');
  });

  it('logs a close that rejects as a warning, with no unhandled rejection', async () => {
    const unhandled: unknown[] = [];
    const recordUnhandled = (reason: unknown) => unhandled.push(reason);
    process.on('unhandledRejection', recordUnhandled);
    try {
      vi.spyOn(McpServer.prototype, 'close').mockRejectedValue(new Error('close failed'));
      const { app: target, logLines } = mounted(DEBUG_MCP_SWITCHED_ON);
      expect((await post(target)).statusCode).toBe(HTTP_OK);
      await new Promise((resolve) => setImmediate(resolve));
      expect(logLines.filter((line) => line.msg === 'debug MCP close failed').length).toBeGreaterThan(0);
      expect(unhandled).toEqual([]);
    } finally {
      process.off('unhandledRejection', recordUnhandled);
    }
  });
});
