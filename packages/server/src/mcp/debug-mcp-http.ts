import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { HTTP_FORBIDDEN, HTTP_INTERNAL_SERVER_ERROR, HTTP_METHOD_NOT_ALLOWED } from './http-status.js';
import { isAllowedDebugMcpRequest } from './loopback-guard.js';

/**
 * The debug MCP over streamable HTTP: dev only and loopback only (README, "MCP visibility").
 * Template-owned: it takes a server factory and names nothing game-specific, so a fix here
 * reaches every game through `preffect-dev sync-template`.
 */

export const DEBUG_MCP_PATH = '/debug-mcp';

/** The environment switch that mounts the debug MCP. Off unless set to exactly this value. */
export const DEBUG_MCP_SWITCH = 'DEBUG_MCP';
export const DEBUG_MCP_ENABLED_VALUE = '1';
/** The debug MCP's name in its log lines. */
const DEBUG_MCP_LABEL = 'debug MCP';

/** JSON-RPC's code for a server-defined error, as the SDK's stateless example uses for a refused request. */
export const JSON_RPC_SERVER_ERROR = -32000;
export const JSON_RPC_INTERNAL_ERROR = -32603;

/** Builds a debug MCP server with every tool registered. Called once at mount, then once per request. */
export type DebugMcpServerFactory = () => McpServer;

export interface JsonRpcErrorBody {
  jsonrpc: '2.0';
  error: { code: number; message: string };
  id: null;
}

export function isDebugMcpEnabled(environment: NodeJS.ProcessEnv): boolean {
  return environment[DEBUG_MCP_SWITCH] === DEBUG_MCP_ENABLED_VALUE;
}

/** Every refusal and failure answers in this one shape. */
export function jsonRpcErrorBody(code: number, message: string): JsonRpcErrorBody {
  return { jsonrpc: '2.0', error: { code, message }, id: null };
}

async function refuseUnlessLoopback(request: FastifyRequest, reply: FastifyReply): Promise<FastifyReply | undefined> {
  const source = {
    host: request.headers.host,
    origin: request.headers.origin,
    peerAddress: request.socket.remoteAddress,
  };
  if (isAllowedDebugMcpRequest(source)) return undefined;
  return reply
    .code(HTTP_FORBIDDEN)
    .send(jsonRpcErrorBody(JSON_RPC_SERVER_ERROR, 'The debug MCP only answers clients on localhost'));
}

/** After the hijack Fastify answers nothing, so a failure is answered here: a 500 if possible, else a cut connection. */
function answerFailure(error: unknown, request: FastifyRequest, reply: FastifyReply, label: string): void {
  request.log.error({ err: error }, `${label} request failed`);
  if (reply.raw.headersSent) {
    reply.raw.destroy(error instanceof Error ? error : undefined);
    return;
  }
  reply.raw.writeHead(HTTP_INTERNAL_SERVER_ERROR, { 'content-type': 'application/json' });
  reply.raw.end(JSON.stringify(jsonRpcErrorBody(JSON_RPC_INTERNAL_ERROR, 'Internal server error')));
}

/** What a stateless request takes from the MCP that answers it: a name for its logs, and hooks around the transport. */
export interface StatelessRequestHooks {
  /** The MCP's name in log lines, such as 'debug MCP'. */
  readonly label: string;
  /** Called with the request's fresh transport before it connects, to watch what it sends. */
  readonly onTransport?: (transport: StreamableHTTPServerTransport) => void;
  /** Called once the reply has closed, answered or not. */
  readonly onClose?: () => void;
  /** Called when the request fails before it's answered. */
  readonly onFailure?: () => void;
}

/**
 * Answers one request in the SDK's stateless mode, which needs a fresh transport per request; an
 * McpServer connects to one transport, so it is fresh too. The reply is hijacked first because the
 * transport writes the raw response itself, and a failed close is logged, never left unhandled.
 * Shared by the debug MCP and the prod MCP.
 */
export async function answerStatelessMcpRequest(
  createServer: () => McpServer,
  request: FastifyRequest,
  reply: FastifyReply,
  hooks: StatelessRequestHooks,
): Promise<void> {
  reply.hijack();
  const warnOnCloseFailure = (error: unknown) => request.log.warn({ err: error }, `${hooks.label} close failed`);
  try {
    const mcp = createServer();
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
    hooks.onTransport?.(transport);
    reply.raw.on('close', () => {
      hooks.onClose?.();
      transport.close().catch(warnOnCloseFailure);
      mcp.close().catch(warnOnCloseFailure);
    });
    await mcp.connect(transport);
    await transport.handleRequest(request.raw, reply.raw, request.body);
  } catch (error) {
    hooks.onFailure?.();
    answerFailure(error, request, reply, hooks.label);
  }
}

function answerMcpRequest(
  createServer: DebugMcpServerFactory,
  request: FastifyRequest,
  reply: FastifyReply,
): Promise<void> {
  return answerStatelessMcpRequest(createServer, request, reply, {
    label: DEBUG_MCP_LABEL,
    onClose: () =>
      request.log.debug(
        { method: request.method, statusCode: reply.raw.statusCode },
        `${DEBUG_MCP_LABEL} request answered`,
      ),
  });
}

/** Stateless mode has no stream to open (GET) or session to end (DELETE), and a GET stream would never close. */
async function refuseMethod(_request: FastifyRequest, reply: FastifyReply): Promise<FastifyReply> {
  return reply
    .code(HTTP_METHOD_NOT_ALLOWED)
    .header('allow', 'POST')
    .send(jsonRpcErrorBody(JSON_RPC_SERVER_ERROR, 'Method not allowed.'));
}

/** Builds one server at mount, so a broken tool registration fails at start-up rather than on every call. */
function checkServerBuilds(server: FastifyInstance, createServer: DebugMcpServerFactory): void {
  createServer()
    .close()
    .catch((error: unknown) => server.log.warn({ err: error }, `${DEBUG_MCP_LABEL} close failed`));
}

function mountUngated(server: FastifyInstance, createServer: DebugMcpServerFactory): void {
  void server.register(async (scope) => {
    scope.addHook('onRequest', refuseUnlessLoopback);
    scope.post(DEBUG_MCP_PATH, (request, reply) => answerMcpRequest(createServer, request, reply));
    scope.route({ method: ['GET', 'DELETE'], url: DEBUG_MCP_PATH, handler: refuseMethod });
  });
}

/**
 * Mounts `/debug-mcp` when `DEBUG_MCP=1` and answers whether it did. POST only, for loopback
 * clients only. The check is in here, not in the caller, so every call site is gated.
 */
export function mountDebugMcpHttp(
  server: FastifyInstance,
  createServer: DebugMcpServerFactory,
  environment: NodeJS.ProcessEnv = process.env,
): boolean {
  if (!isDebugMcpEnabled(environment)) return false;
  checkServerBuilds(server, createServer);
  mountUngated(server, createServer);
  return true;
}
