import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import type { DebugContext } from '../debug-context.js';

/**
 * EXTENSION POINT — game-specific MCP tools.
 *
 * This file is intentionally empty plumbing. The init step adds tools here that
 * expose your game's domain state to Claude via the /debug-mcp endpoint, e.g.:
 *
 *   mcp.tool(
 *     'debug_get_entities',
 *     'List all entities in a room',
 *     { gameId: z.string().describe('The game ID') },
 *     (args) =>
 *       withActiveRoom(ctx, args.gameId, (room) => {
 *         // TODO(game): read structured game state off the room / GameModule.
 *         const entities = []; // e.g. room.getEntities()
 *         return jsonResult(entities); // ../tool-result.js, ../active-room.js
 *       }),
 *   );
 *
 * The generic handlers in this directory show the shape.
 * Registered by mcp-server.ts after the generic tools, so it is a no-op until
 * you fill it in.
 */
export function registerGameSpecificTools(_mcp: McpServer, _ctx: DebugContext): void {
  // TODO(game): register game-specific debug tools here (entities, tiles, scores, ...).
}
