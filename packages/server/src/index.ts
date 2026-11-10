import Fastify from 'fastify';
import fastifyWebsocket from '@fastify/websocket';
import { DEFAULT_SERVER_PORT } from '@base-multiplayer-game/shared';
import { LobbyManager } from './lobby/lobby-manager.js';
import { registerWebSocketHandler } from './ws/websocket-handler.js';
import type { Connection } from './ws/connection.js';
import { DEBUG_MCP_PATH } from './mcp/debug-mcp-http.js';
import { createDebugMcpServer, mountDebugMcp } from './mcp/mcp-server.js';
import { PRODUCTION_MCP_PATH, startProductionMcp } from './mcp/prod-mcp-http.js';
import { defaultGameModuleFactory } from './game/game-module.js'; // TODO(init): swap for real factory

const PORT = Number(process.env.PORT) || DEFAULT_SERVER_PORT;

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

  // The /debug-mcp endpoint surfaces all game state to Claude via MCP: dev only, loopback only (README).
  // TODO(init): wire `getRoomGameState` to expose real game state per room.
  if (mountDebugMcp(server, { lobbyManager, connections })) {
    server.log.info(`Debug MCP on ${DEBUG_MCP_PATH}`);
  }

  await server.listen({ port: PORT, host: '0.0.0.0' });

  // The prod MCP, the same tools on a port of their own for this game's dev workspace (README, "Prod MCP"):
  // off unless MCP_PORT is set, and only with the app's token.
  const productionMcp = await startProductionMcp(() => createDebugMcpServer({ lobbyManager, connections }));
  if (productionMcp !== undefined) server.log.info(`Prod MCP on ${PRODUCTION_MCP_PATH}, port ${process.env.MCP_PORT}`);
}

main().catch((err) => {
  console.error('Server failed to start:', err);
  process.exit(1);
});
