import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import type { DebugContext } from '../debug-context.js';

/** Generic server + per-room performance/heartbeat tools. */
export function registerPerformanceTools(mcp: McpServer, ctx: DebugContext): void {
  mcp.tool(
    'debug_get_performance',
    'Get server-wide performance metrics (uptime, memory, room/connection counts)',
    () => {
      const mem = process.memoryUsage();
      const uptime = process.uptime();
      const activeRooms = ctx.lobbyManager.listActiveRooms().size;
      const pendingGames = ctx.lobbyManager.listPendingGames().size;
      const totalConnections = ctx.connections.size;

      return {
        content: [
          {
            type: 'text',
            text: JSON.stringify(
              {
                uptimeSeconds: Math.round(uptime),
                memoryMB: {
                  rss: Math.round(mem.rss / 1024 / 1024),
                  heapUsed: Math.round(mem.heapUsed / 1024 / 1024),
                  heapTotal: Math.round(mem.heapTotal / 1024 / 1024),
                },
                activeRooms,
                pendingGames,
                totalConnections,
              },
              null,
              2,
            ),
          },
        ],
      };
    },
  );

  mcp.tool(
    'debug_get_room_performance',
    'Get per-room tick timings, snapshot byte sizes, broadcast fan-out, and merged client perf/heartbeat reports. Omit gameId for all active rooms.',
    { gameId: z.string().optional().describe('Optional game ID. If omitted, returns all active rooms.') },
    (args) => {
      const rooms = args.gameId
        ? (() => {
            const r = ctx.lobbyManager.getActiveRoom(args.gameId!);
            return r ? [[args.gameId!, r] as const] : [];
          })()
        : Array.from(ctx.lobbyManager.listActiveRooms().entries());

      if (rooms.length === 0) {
        return {
          content: [{ type: 'text', text: args.gameId ? `Room "${args.gameId}" not found` : 'No active rooms' }],
          isError: !!args.gameId,
        };
      }

      const result = rooms.map(([gameId, room]) => ({
        gameId,
        playerCount: room.playerConnections.size,
        ...room.perfTracker.getStats(),
      }));

      return { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }] };
    },
  );
}
