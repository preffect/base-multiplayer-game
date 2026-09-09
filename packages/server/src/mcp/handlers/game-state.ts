import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import type { DebugContext } from '../debug-context.js';

/**
 * Generic per-room game-state dump.
 *
 * This is the opaque-blob extension stub. By default it returns:
 *   1. `ctx.getRoomGameState(gameId)` if the init step wired it, ELSE
 *   2. the room's opaque snapshot (`room.getSnapshot()`) plus a note that no
 *      game-specific state inspector is wired yet.
 *
 * The init step implements `DebugContext.getRoomGameState` to surface the real,
 * structured game state (entities, scores, tiles, etc.) here.
 */
export function registerGameStateTools(mcp: McpServer, ctx: DebugContext): void {
  mcp.tool(
    'debug_get_game_state',
    'Get the full game-state blob for an active room (game-specific once wired; otherwise the opaque broadcast snapshot)',
    { gameId: z.string().describe('The game ID') },
    (args) => {
      const room = ctx.lobbyManager.getActiveRoom(args.gameId);
      if (!room) {
        return { content: [{ type: 'text', text: `Game "${args.gameId}" not found or not active` }], isError: true };
      }

      const blob = ctx.getRoomGameState?.(args.gameId) ?? {
        note: 'No game-specific state inspector wired yet — implement getRoomGameState in the init step. Falling back to the opaque broadcast snapshot.',
        snapshot: room.getSnapshot(),
      };

      return { content: [{ type: 'text', text: JSON.stringify(blob, null, 2) }] };
    },
  );
}
