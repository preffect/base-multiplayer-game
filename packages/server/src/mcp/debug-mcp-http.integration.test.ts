import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import Fastify, { type FastifyInstance } from 'fastify';
import { request as httpRequest } from 'node:http';
import { afterEach, describe, expect, it } from 'vitest';
import {
  DEBUG_MCP_SWITCHED_ON,
  LOOPBACK_HOST_WITH_PORT,
  LOOPBACK_ORIGIN,
  MCP_INITIALIZE_REQUEST,
  MCP_POST_HEADERS,
  PROBE_TOOL_ANSWER,
  PROBE_TOOL_NAME,
  TEST_CLIENT_INFO,
  createProbeDebugServer,
} from '../testing/debug-mcp-builders.js';
import { DEBUG_MCP_PATH, mountDebugMcpHttp } from './debug-mcp-http.js';
import { HTTP_FORBIDDEN, HTTP_OK } from './http-status.js';

const ANY_FREE_PORT = 0;
const LOOPBACK_LISTEN_HOST = '127.0.0.1';

/** Posts an initialize over a real socket with forged headers, which fetch would not allow, and answers the status. */
function postStatus(address: string, headers: Record<string, string>): Promise<number> {
  return new Promise((resolve, reject) => {
    const outgoing = httpRequest(
      `${address}${DEBUG_MCP_PATH}`,
      { method: 'POST', headers: { ...MCP_POST_HEADERS, ...headers } },
      (response) => {
        response.resume();
        if (response.statusCode === undefined) reject(new Error('response without a status'));
        else resolve(response.statusCode);
      },
    );
    outgoing.on('error', reject);
    outgoing.end(JSON.stringify(MCP_INITIALIZE_REQUEST));
  });
}

describe('/debug-mcp over a real socket', () => {
  let app: FastifyInstance | undefined;
  let client: Client | undefined;

  afterEach(async () => {
    await client?.close();
    await app?.close();
    client = undefined;
    app = undefined;
  });

  async function listen(): Promise<string> {
    app = Fastify();
    mountDebugMcpHttp(app, createProbeDebugServer, DEBUG_MCP_SWITCHED_ON);
    return app.listen({ port: ANY_FREE_PORT, host: LOOPBACK_LISTEN_HOST });
  }

  it('lists and calls tools through the SDK client', async () => {
    client = new Client(TEST_CLIENT_INFO);
    await client.connect(new StreamableHTTPClientTransport(new URL(`${await listen()}${DEBUG_MCP_PATH}`)));
    expect((await client.listTools()).tools.map((tool) => tool.name)).toEqual([PROBE_TOOL_NAME]);
    const result = await client.callTool({ name: PROBE_TOOL_NAME, arguments: {} });
    expect(result.content).toEqual([{ type: 'text', text: PROBE_TOOL_ANSWER }]);
  });

  it.each([LOOPBACK_HOST_WITH_PORT, '127.0.0.1', '[::1]:9000'])('answers the loopback Host %s', async (host) => {
    expect(await postStatus(await listen(), { host })).toBe(HTTP_OK);
  });

  it('answers a loopback Origin', async () => {
    expect(await postStatus(await listen(), { host: LOOPBACK_HOST_WITH_PORT, origin: LOOPBACK_ORIGIN })).toBe(HTTP_OK);
  });

  it('refuses a rebinding Host', async () => {
    expect(await postStatus(await listen(), { host: 'localhost.attacker.example:9000' })).toBe(HTTP_FORBIDDEN);
  });
});
