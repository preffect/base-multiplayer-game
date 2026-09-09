import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import type { FastifyInstance } from 'fastify';
import type { DebugContext } from './debug-context.js';
import { registerConnectionTools } from './handlers/connections.js';
import { registerPerformanceTools } from './handlers/performance.js';
import { registerRoomTools } from './handlers/rooms.js';
import { registerGameStateTools } from './handlers/game-state.js';
import { registerGameSpecificTools } from './handlers/game-specific.js';

/**
 * Mounts the debug MCP server as a Fastify route at `/debug-mcp`.
 *
 * Single-Fastify model: the same instance serves /api + /ws + /debug-mcp.
 * Exposes GENERIC, game-agnostic visibility into all live state:
 *   - connections / players   (connections.ts)
 *   - server + per-room perf   (performance.ts)
 *   - rooms / lobby listing    (rooms.ts)
 *   - per-room game-state blob  (game-state.ts — opaque until wired)
 *   - game-specific tools       (game-specific.ts — extension point, no-op by default)
 *
 * SDK 1.12+ in stateless mode requires a fresh transport per request, and an
 * McpServer (Protocol) can only be connected to one transport, so both are
 * constructed per request. Tool registration is cheap (Map inserts, << 1ms).
 */
export function mountDebugMcp(server: FastifyInstance, ctx: DebugContext): void {
  server.all('/debug-mcp', async (request, reply) => {
    const mcp = new McpServer({ name: 'game-debug', version: '1.0.0' });

    // Generic plumbing tools (always present).
    registerConnectionTools(mcp, ctx);
    registerPerformanceTools(mcp, ctx);
    registerRoomTools(mcp, ctx);
    registerGameStateTools(mcp, ctx);

    // EXTENSION POINT: game-specific tools (no-op until the init step fills it in).
    registerGameSpecificTools(mcp, ctx);

    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
    reply.raw.on('close', () => {
      void transport.close();
      void mcp.close();
    });
    await mcp.connect(transport);
    await transport.handleRequest(request.raw, reply.raw, request.body as unknown);
    reply.hijack();
  });
}

/**
 * Back-compat alias matching the BUILD SPEC §C.15 wiring
 * (`registerMcpEndpoint(server, ctx)`). Identical behavior to `mountDebugMcp`.
 */
export const registerMcpEndpoint = mountDebugMcp;
