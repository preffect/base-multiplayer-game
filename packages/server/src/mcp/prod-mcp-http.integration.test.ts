import type { AddressInfo } from 'node:net';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import type { FastifyInstance } from 'fastify';
import { afterEach, describe, expect, it } from 'vitest';
import { buildEmptyDebugContext } from '../testing/debug-context-builders.js';
import { TEST_CLIENT_INFO } from '../testing/debug-mcp-builders.js';
import { PROD_MCP_TEST_TOKEN, prodMcpEnvironment } from '../testing/prod-mcp-builders.js';
import type { CallLogLine } from './call-log.js';
import { createDebugMcpServer } from './mcp-server.js';
import { BEARER_PREFIX, PROD_MCP_PATH, startProdMcp } from './prod-mcp-http.js';

describe('the prod MCP with the game tools', () => {
  let app: FastifyInstance | undefined;
  let client: Client | undefined;

  afterEach(async () => {
    await client?.close();
    await app?.close();
    client = undefined;
    app = undefined;
  });

  it('serves the debug tools to a caller with the token, and logs each call', async () => {
    const lines: CallLogLine[] = [];
    const context = buildEmptyDebugContext();
    app = await startProdMcp(
      () => createDebugMcpServer(context),
      prodMcpEnvironment('0'),
      (line) => lines.push(line),
    );
    const port = (app?.server.address() as AddressInfo).port;
    client = new Client(TEST_CLIENT_INFO);
    await client.connect(
      new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}${PROD_MCP_PATH}`), {
        requestInit: { headers: { authorization: `${BEARER_PREFIX}${PROD_MCP_TEST_TOKEN}` } },
      }),
    );
    expect((await client.listTools()).tools.map((tool) => tool.name)).toContain('debug_list_games');
    const result = await client.callTool({ name: 'debug_list_games', arguments: {} });
    expect(result.content).toEqual([{ type: 'text', text: '[]' }]);
    expect(lines.at(-1)).toMatchObject({ method: 'tools/call', tool: 'debug_list_games', outcome: 'ok' });
  });
});
