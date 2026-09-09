import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import type { DebugContext } from '../debug-context.js';

/** Generic, game-agnostic room/lobby visibility tools. */
export function registerRoomTools(mcp: McpServer, ctx: DebugContext): void {
  mcp.tool('debug_list_games', 'List all pending (lobby) and active games with player counts', () => {
    const pending = Array.from(ctx.lobbyManager.listPendingGames().entries()).map(([id, g]) => ({
      gameId: id,
      status: 'pending' as const,
      gameName: g.gameName,
      creatorId: g.creatorId,
      playerCount: g.players.size,
      maxPlayers: g.config.maxPlayers,
    }));

    const active = Array.from(ctx.lobbyManager.listActiveRooms().entries()).map(([id, room]) => ({
      gameId: id,
      status: 'active' as const,
      gameName: room.gameName,
      creatorId: room.creatorId,
      playerCount: room.playerConnections.size,
      maxPlayers: room.sessionConfig.maxPlayers,
    }));

    return { content: [{ type: 'text', text: JSON.stringify([...pending, ...active], null, 2) }] };
  });

  mcp.tool(
    'debug_get_room',
    'Get room membership metadata for an active game (connected, disconnected, and all player ids)',
    { gameId: z.string().describe('The game ID to inspect') },
    (args) => {
      const room = ctx.lobbyManager.getActiveRoom(args.gameId);
      if (!room) {
        return { content: [{ type: 'text', text: `Game "${args.gameId}" not found or not active` }], isError: true };
      }
      const state = {
        gameId: args.gameId,
        gameName: room.gameName,
        creatorId: room.creatorId,
        maxPlayers: room.sessionConfig.maxPlayers,
        connected: Array.from(room.playerConnections.keys()),
        disconnected: Array.from(room.disconnectedPlayers),
        allPlayerIds: room.allPlayerIds,
      };
      return { content: [{ type: 'text', text: JSON.stringify(state, null, 2) }] };
    },
  );
}
