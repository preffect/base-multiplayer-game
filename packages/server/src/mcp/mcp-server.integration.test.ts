import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import Fastify, { type FastifyInstance } from 'fastify';
import { request as httpRequest } from 'node:http';
import { afterEach, describe, expect, it } from 'vitest';
import {
  DEBUG_MCP_SWITCHED_ON,
  MCP_INITIALIZE_REQUEST,
  MCP_POST_HEADERS,
  buildEmptyDebugContext,
} from '../testing/debug-context-builders.js';
import { DEBUG_MCP_PATH, mountDebugMcpWhenEnabled } from './mcp-server.js';

const ANY_FREE_PORT = 0;
const LOOPBACK_HOST = '127.0.0.1';
const HTTP_OK = 200;
const HTTP_FORBIDDEN = 403;

/** Posts an initialize over a real socket with a forged Host, which fetch would not allow, and answers the status. */
function postStatus(address: string, host: string): Promise<number> {
  return new Promise((resolve, reject) => {
    const outgoing = httpRequest(
      `${address}${DEBUG_MCP_PATH}`,
      { method: 'POST', headers: { ...MCP_POST_HEADERS, host } },
      (response) => {
        response.resume();
        resolve(response.statusCode ?? 0);
      },
    );
    outgoing.on('error', reject);
    outgoing.end(JSON.stringify(MCP_INITIALIZE_REQUEST));
  });
}

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
    mountDebugMcpWhenEnabled(server, buildEmptyDebugContext(), DEBUG_MCP_SWITCHED_ON);
    return server.listen({ port: ANY_FREE_PORT, host: LOOPBACK_HOST });
  }

  it('serves the debug tools over HTTP, with the argument schemas intact', async () => {
    const address = await listen();
    client = new Client({ name: 'test', version: '1.0.0' });
    await client.connect(new StreamableHTTPClientTransport(new URL(`${address}${DEBUG_MCP_PATH}`)));

    const { tools } = await client.listTools();
    expect(tools.map((tool) => tool.name)).toContain('debug_list_games');
    expect(tools.find((tool) => tool.name === 'debug_get_room')?.inputSchema.required).toEqual(['gameId']);

    const result = await client.callTool({ name: 'debug_list_games', arguments: {} });
    expect(result.content).toEqual([{ type: 'text', text: '[]' }]);
  });

  it.each(['localhost:4400', '127.0.0.1', '[::1]:4400'])(
    'answers the loopback Host %s on a real socket',
    async (host) => {
      expect(await postStatus(await listen(), host)).toBe(HTTP_OK);
    },
  );

  it('refuses a rebinding Host on a real socket', async () => {
    expect(await postStatus(await listen(), 'localhost.attacker.example:4400')).toBe(HTTP_FORBIDDEN);
  });
});
