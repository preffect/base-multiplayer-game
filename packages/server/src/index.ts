import Fastify from 'fastify';
import fastifyWebsocket from '@fastify/websocket';
import { DEFAULT_SERVER_PORT } from '@base-multiplayer-game/shared';
import { LobbyManager } from './lobby/lobby-manager.js';
import { registerWebSocketHandler } from './ws/websocket-handler.js';
import type { Connection } from './ws/connection.js';
import { DEBUG_MCP_PATH, DEBUG_MCP_SWITCH, mountDebugMcpWhenEnabled } from './mcp/mcp-server.js';
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

  // The /debug-mcp endpoint surfaces all game state to Claude via MCP. Dev only (DEBUG_MCP=1), loopback only.
  // TODO(init): wire `getRoomGameState` to expose real game state per room.
  if (mountDebugMcpWhenEnabled(server, { lobbyManager, connections }, process.env)) {
    server.log.info(`Debug MCP on ${DEBUG_MCP_PATH} (${DEBUG_MCP_SWITCH} is on, loopback only)`);
  }

  await server.listen({ port: PORT, host: '0.0.0.0' });
}

main().catch((err) => {
  console.error('Server failed to start:', err);
  process.exit(1);
});
