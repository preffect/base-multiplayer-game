import type { AddressInfo } from 'node:net';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import Fastify, { type FastifyInstance } from 'fastify';
import { afterEach, describe, expect, it } from 'vitest';
import { buildEmptyDebugContext } from '../testing/debug-context-builders.js';
import { DEBUG_MCP_SWITCHED_ON, TEST_CLIENT_INFO } from '../testing/debug-mcp-builders.js';
import { PRODUCTION_MCP_TEST_TOKEN, productionMcpEnvironment } from '../testing/prod-mcp-builders.js';
import type { CallLogLine } from './call-log.js';
import { DEBUG_MCP_PATH } from './debug-mcp-http.js';
import { createDebugMcpServer, mountDebugMcp } from './mcp-server.js';
import { BEARER_PREFIX, PRODUCTION_MCP_PATH, startProductionMcp } from './prod-mcp-http.js';

const ANY_FREE_PORT = 0;
const LOOPBACK_HOST = '127.0.0.1';

describe('/debug-mcp', () => {
  let server: FastifyInstance | undefined;
  let client: Client | undefined;

  afterEach(async () => {
    await client?.close();
    await server?.close();
    client = undefined;
    server = undefined;
  });

  async function listen(): Promise<string> {
    server = Fastify();
    mountDebugMcp(server, buildEmptyDebugContext(), DEBUG_MCP_SWITCHED_ON);
    return server.listen({ port: ANY_FREE_PORT, host: LOOPBACK_HOST });
  }

  it('serves the game debug tools over HTTP, with the argument schemas intact', async () => {
    const address = await listen();
    client = new Client(TEST_CLIENT_INFO);
    await client.connect(new StreamableHTTPClientTransport(new URL(`${address}${DEBUG_MCP_PATH}`)));

    const { tools } = await client.listTools();
    expect(tools.map((tool) => tool.name)).toContain('debug_list_games');
    expect(tools.find((tool) => tool.name === 'debug_get_room')?.inputSchema.required).toEqual(['gameId']);

    const result = await client.callTool({ name: 'debug_list_games', arguments: {} });
    expect(result.content).toEqual([{ type: 'text', text: '[]' }]);
  });
});

describe('the prod MCP with the game tools', () => {
  let app: FastifyInstance | undefined;
  let client: Client | undefined;

  afterEach(async () => {
    await client?.close();
    await app?.close();
    client = undefined;
    app = undefined;
  });

  it('serves the game debug tools to a caller with the token, and logs each call', async () => {
    const lines: CallLogLine[] = [];
    const context = buildEmptyDebugContext();
    app = await startProductionMcp(
      () => createDebugMcpServer(context),
      productionMcpEnvironment(String(ANY_FREE_PORT)),
      (line) => lines.push(line),
    );
    const address = `http://${LOOPBACK_HOST}:${(app?.server.address() as AddressInfo).port}`;
    client = new Client(TEST_CLIENT_INFO);
    await client.connect(
      new StreamableHTTPClientTransport(new URL(`${address}${PRODUCTION_MCP_PATH}`), {
        requestInit: { headers: { authorization: `${BEARER_PREFIX}${PRODUCTION_MCP_TEST_TOKEN}` } },
      }),
    );
    expect((await client.listTools()).tools.map((tool) => tool.name)).toContain('debug_list_games');
    const result = await client.callTool({ name: 'debug_list_games', arguments: {} });
    expect(result.content).toEqual([{ type: 'text', text: '[]' }]);
    expect(lines.at(-1)).toMatchObject({ method: 'tools/call', tool: 'debug_list_games', outcome: 'ok' });
  });
});
