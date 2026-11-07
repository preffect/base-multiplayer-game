import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import Fastify, { type FastifyInstance } from 'fastify';
import { afterEach, describe, expect, it } from 'vitest';
import { defaultGameModuleFactory } from '../game/game-module.js';
import { LobbyManager } from '../lobby/lobby-manager.js';
import { mountDebugMcp } from './mcp-server.js';

const ANY_FREE_PORT = 0;

describe('/debug-mcp', () => {
  let server: FastifyInstance | undefined;
  let client: Client | undefined;

  afterEach(async () => {
    await client?.close();
    await server?.close();
  });

  it('serves the debug tools over HTTP, with the argument schemas intact', async () => {
    server = Fastify();
    mountDebugMcp(server, { lobbyManager: new LobbyManager(defaultGameModuleFactory), connections: new Map() });
    const address = await server.listen({ port: ANY_FREE_PORT, host: '127.0.0.1' });

    client = new Client({ name: 'test', version: '1.0.0' });
    await client.connect(new StreamableHTTPClientTransport(new URL(`${address}/debug-mcp`)));

    const { tools } = await client.listTools();
    expect(tools.map((tool) => tool.name)).toContain('debug_list_games');
    expect(tools.find((tool) => tool.name === 'debug_get_room')?.inputSchema.required).toEqual(['gameId']);

    const result = await client.callTool({ name: 'debug_list_games', arguments: {} });
    expect(result.content).toEqual([{ type: 'text', text: '[]' }]);
  });
});
