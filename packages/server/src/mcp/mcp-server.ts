import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import type { FastifyInstance } from 'fastify';
import type { DebugContext } from './debug-context.js';
import { mountDebugMcpHttp } from './debug-mcp-http.js';
import { registerConnectionTools } from './handlers/connections.js';
import { registerPerformanceTools } from './handlers/performance.js';
import { registerRoomTools } from './handlers/rooms.js';
import { registerGameStateTools } from './handlers/game-state.js';
import { registerGameSpecificTools } from './handlers/game-specific.js';

const DEBUG_SERVER_INFO = { name: 'game-debug', version: '1.0.0' };

/**
 * A debug MCP server with this game's tools. Exposes GENERIC, game-agnostic visibility into all
 * live state:
 *   - connections / players   (connections.ts)
 *   - server + per-room perf   (performance.ts)
 *   - rooms / lobby listing    (rooms.ts)
 *   - per-room game-state blob  (game-state.ts — opaque until wired)
 *   - game-specific tools       (game-specific.ts — extension point, no-op by default)
 */
export function createDebugMcpServer(ctx: DebugContext): McpServer {
  const mcp = new McpServer(DEBUG_SERVER_INFO);
  registerConnectionTools(mcp, ctx);
  registerPerformanceTools(mcp, ctx);
  registerRoomTools(mcp, ctx);
  registerGameStateTools(mcp, ctx);
  // EXTENSION POINT: game-specific tools (no-op until the init step fills it in).
  registerGameSpecificTools(mcp, ctx);
  return mcp;
}

/**
 * Mounts `/debug-mcp` with this game's tools: dev only and loopback only (debug-mcp-http.ts).
 * Answers whether it mounted.
 */
export function mountDebugMcp(
  server: FastifyInstance,
  ctx: DebugContext,
  environment: NodeJS.ProcessEnv = process.env,
): boolean {
  return mountDebugMcpHttp(server, () => createDebugMcpServer(ctx), environment);
}

/**
 * @deprecated Use `mountDebugMcp`. Kept, gated the same way, so a game whose `index.ts` still
 * calls it gets the switch and the loopback check once this file is copied in.
 */
export const registerMcpEndpoint = mountDebugMcp;
