import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import type { DebugContext } from '../debug-context.js';

/** Generic, game-agnostic connection/player visibility tools. */
export function registerConnectionTools(mcp: McpServer, ctx: DebugContext): void {
  mcp.tool('debug_get_connections', 'List all active WebSocket connections (players currently connected)', () => {
    const conns = Array.from(ctx.connections.values()).map((c) => ({
      playerId: c.playerId,
      playerName: c.playerName,
      avatarIndex: c.avatarIndex,
      readyState: c.socket.readyState,
    }));
    return { content: [{ type: 'text', text: JSON.stringify(conns, null, 2) }] };
  });
}
