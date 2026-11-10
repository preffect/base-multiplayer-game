import type { AddressInfo } from 'node:net';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import type { FastifyInstance } from 'fastify';
import { afterEach, describe, expect, it } from 'vitest';
import { TEST_CLIENT_INFO } from '../testing/debug-mcp-builders.js';
import {
  PRODUCTION_MCP_TEST_TOKEN,
  SETTING_TOOL_ANSWER,
  SETTING_TOOL_NAME,
  createProbeProductionServer,
  productionMcpEnvironment,
} from '../testing/prod-mcp-builders.js';
import type { CallLogLine } from './call-log.js';
import { BEARER_PREFIX, PRODUCTION_MCP_PATH, startProductionMcp } from './prod-mcp-http.js';

/**
 * Template-owned: the prod MCP through the MCP SDK's own client, with the probe server standing in for a game's
 * tools. A game's own tools through it are tested beside its server (mcp-server.integration.test.ts).
 */
describe('the prod MCP through the MCP client', () => {
  let app: FastifyInstance | undefined;
  let client: Client | undefined;

  afterEach(async () => {
    await client?.close();
    await app?.close();
    client = undefined;
    app = undefined;
  });

  it('serves the tools to a caller with the token, and logs each call', async () => {
    const lines: CallLogLine[] = [];
    app = await startProductionMcp(createProbeProductionServer, productionMcpEnvironment('0'), (line) =>
      lines.push(line),
    );
    const port = (app?.server.address() as AddressInfo).port;
    client = new Client(TEST_CLIENT_INFO);
    await client.connect(
      new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}${PRODUCTION_MCP_PATH}`), {
        requestInit: { headers: { authorization: `${BEARER_PREFIX}${PRODUCTION_MCP_TEST_TOKEN}` } },
      }),
    );
    expect((await client.listTools()).tools.map((tool) => tool.name)).toContain(SETTING_TOOL_NAME);
    const result = await client.callTool({ name: SETTING_TOOL_NAME, arguments: { value: 'v' } });
    expect(result.content).toEqual([{ type: 'text', text: SETTING_TOOL_ANSWER }]);
    expect(lines.at(-1)).toMatchObject({ method: 'tools/call', tool: SETTING_TOOL_NAME, outcome: 'ok' });
  });
});
