import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import type { DebugContext } from './debug-context.js';
import { registerConnectionTools } from './handlers/connections.js';
import { registerPerformanceTools } from './handlers/performance.js';
import { registerRoomTools } from './handlers/rooms.js';
import { registerGameStateTools } from './handlers/game-state.js';
import { registerGameSpecificTools } from './handlers/game-specific.js';
import { refuseNonLoopback } from './loopback-guard.js';

export const DEBUG_MCP_PATH = '/debug-mcp';

/** The environment switch that mounts the debug MCP. Off unless set to exactly this value. */
export const DEBUG_MCP_SWITCH = 'DEBUG_MCP';
export const DEBUG_MCP_ENABLED_VALUE = '1';

const DEBUG_SERVER_INFO = { name: 'game-debug', version: '1.0.0' };

const HTTP_METHOD_NOT_ALLOWED = 405;
/** JSON-RPC's code for a server-defined error, as the SDK's stateless example uses for a refused method. */
const JSON_RPC_SERVER_ERROR = -32000;

/**
 * A debug MCP server with every tool registered against `ctx`. Exposes GENERIC, game-agnostic
 * visibility into all live state:
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

export function isDebugMcpEnabled(environment: NodeJS.ProcessEnv): boolean {
  return environment[DEBUG_MCP_SWITCH] === DEBUG_MCP_ENABLED_VALUE;
}

/**
 * Answers one MCP request in the SDK's stateless mode. That mode needs a fresh transport per
 * request, and an McpServer can only be connected to one transport, so both are built here
 * (tool registration is cheap). The reply is hijacked first because the transport writes the raw
 * response itself, and a failed close is logged rather than left to crash the process.
 */
async function answerMcpRequest(ctx: DebugContext, request: FastifyRequest, reply: FastifyReply): Promise<void> {
  reply.hijack();
  const mcp = createDebugMcpServer(ctx);
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  const warnOnCloseFailure = (error: unknown) => request.log.warn({ err: error }, 'debug MCP close failed');
  reply.raw.on('close', () => {
    transport.close().catch(warnOnCloseFailure);
    mcp.close().catch(warnOnCloseFailure);
  });
  await mcp.connect(transport);
  await transport.handleRequest(request.raw, reply.raw, request.body);
}

/** Stateless mode has no stream to open (GET) or session to end (DELETE), and a GET stream would never close. */
async function refuseMethod(_request: FastifyRequest, reply: FastifyReply): Promise<FastifyReply> {
  return reply
    .code(HTTP_METHOD_NOT_ALLOWED)
    .header('allow', 'POST')
    .send({ jsonrpc: '2.0', error: { code: JSON_RPC_SERVER_ERROR, message: 'Method not allowed.' }, id: null });
}

/**
 * Mounts the debug MCP at `/debug-mcp` over streamable HTTP, on the same Fastify instance as
 * /api and /ws. It answers POST only, and only to loopback Host and Origin headers.
 */
export function mountDebugMcp(server: FastifyInstance, ctx: DebugContext): void {
  server.post(DEBUG_MCP_PATH, { onRequest: refuseNonLoopback }, (request, reply) =>
    answerMcpRequest(ctx, request, reply),
  );
  server.route({ method: ['GET', 'DELETE'], url: DEBUG_MCP_PATH, onRequest: refuseNonLoopback, handler: refuseMethod });
}

/** Mounts the debug MCP only when `DEBUG_MCP=1`; the server's dev script and run.sh set it, `start` does not. */
export function mountDebugMcpWhenEnabled(
  server: FastifyInstance,
  ctx: DebugContext,
  environment: NodeJS.ProcessEnv,
): boolean {
  if (!isDebugMcpEnabled(environment)) return false;
  mountDebugMcp(server, ctx);
  return true;
}

/**
 * Back-compat alias matching the BUILD SPEC §C.15 wiring
 * (`registerMcpEndpoint(server, ctx)`). Identical behavior to `mountDebugMcp`.
 */
export const registerMcpEndpoint = mountDebugMcp;
