import Fastify from 'fastify';
import fastifyWebsocket from '@fastify/websocket';
import { LobbyManager } from './lobby/lobby-manager.js';
import { registerWebSocketHandler } from './ws/websocket-handler.js';
import type { Connection } from './ws/connection.js';
import { registerMcpEndpoint } from './mcp/mcp-server.js';
import { defaultGameModuleFactory } from './game/game-module.js'; // TODO(init): swap for real factory

const PORT = Number(process.env.PORT) || 4400;

async function main(): Promise<void> {
  const server = Fastify({ logger: true });

  await server.register(fastifyWebsocket, {
    options: {
      perMessageDeflate: {
        zlibDeflateOptions: { level: 1 },
        threshold: 256,
        concurrencyLimit: 10,
      },
    },
  });

  const lobbyManager = new LobbyManager(defaultGameModuleFactory);
  const connections = new Map<string, Connection>();
  const handlers = lobbyManager.createHandlers(connections);

  registerWebSocketHandler(server, {
    connections,
    handlers,
    onConnect: (c) => lobbyManager.handleConnect(c, connections),
    onDisconnect: (c) => lobbyManager.handleDisconnect(c),
  });

  server.get('/api/health', async () => ({ status: 'ok' }));

  // The /debug-mcp endpoint surfaces all game state to Claude via MCP.
  // TODO(init): wire `getRoomGameState` to expose real game state per room.
  registerMcpEndpoint(server, { lobbyManager, connections });

  await server.listen({ port: PORT, host: '0.0.0.0' });
}

main().catch((err) => {
  console.error('Server failed to start:', err);
  process.exit(1);
});
